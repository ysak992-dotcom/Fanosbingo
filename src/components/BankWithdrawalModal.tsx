/**
 * Requesting a bank payout.
 *
 * WHAT CHANGED, and why the old version could never have worked.
 *
 * handleSubmit used to INSERT into withdrawal_requests directly:
 *
 *   supabase.from('withdrawal_requests').insert({ telegram_user_id, amount, ... })
 *
 * db/20-post/007 gives that table no INSERT policy at all, deliberately, and
 * says so in a comment naming this file: a client-side insert sets
 * telegram_user_id and amount with no balance check and no serialisation, so a
 * player could file against somebody else's balance, or ten against their own at
 * once. The insert therefore failed on RLS -- correctly -- and this modal was
 * also mounted nowhere, so nobody hit it.
 *
 * It now POSTs /withdrawals/request, which calls request_bank_withdrawal(): the
 * player's row is locked FOR UPDATE, available balance is won_balance minus
 * everything already pending, and the identity comes from the JWT rather than
 * from this component.
 */

import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';
import { getAccessToken } from '../lib/auth';
import { X, Building2, AlertCircle, CheckCircle } from 'lucide-react';

const API = import.meta.env.VITE_SUPABASE_URL;

/** Matches request_bank_withdrawal's own floor. */
const MIN_WITHDRAWAL_ETB = 100;

interface WithdrawalBank {
  id: string;
  bank_name: string;
  is_active: boolean;
  display_order: number;
}

interface BankWithdrawalModalProps {
  isOpen: boolean;
  onClose: () => void;
  telegramUserId: number;
  wonBalance: number;
  onSuccess: () => void;
}

export function BankWithdrawalModal({
  isOpen,
  onClose,
  telegramUserId,
  wonBalance,
  onSuccess
}: BankWithdrawalModalProps) {
  const [step, setStep] = useState<'amount' | 'bank' | 'account' | 'name' | 'confirm'>('amount');
  const [amount, setAmount] = useState('');
  // The bank OPTION ID, not its name.
  //
  // /withdrawals/request resolves the name from withdrawal_bank_options itself
  // and ignores anything this component might send, for the same reason the
  // deposit claim does: a request naming an account that was never ours is one
  // the operator has to disprove.
  const [selectedBank, setSelectedBank] = useState<string>('');
  const [accountNumber, setAccountNumber] = useState('');
  const [accountName, setAccountName] = useState('');
  const [banks, setBanks] = useState<WithdrawalBank[]>([]);
  // Value unread: there is no spinner on the initial banks/balance fetch.
  // The SUBMIT button is guarded by isSubmitting, so this is a missing
  // indicator rather than a double-submit risk.
  const [, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pendingWithdrawals, setPendingWithdrawals] = useState(0);
  const [isSubmitting, setIsSubmitting] = useState(false);

  // FROM THE SERVER, not computed here.
  //
  // This was `wonBalance - pendingWithdrawals`, summed from a table read. The
  // arithmetic was right, but the number a player is shown and the number
  // request_bank_withdrawal() enforces have to come from ONE expression -- or
  // the form offers an amount the server then refuses, which reads as a bug in
  // the game rather than as the race it is. /withdrawals/available calls
  // get_available_balance(), which is what the request path itself uses.
  //
  // Falls back to the local calculation only until the fetch resolves.
  const [serverAvailable, setServerAvailable] = useState<number | null>(null);
  const availableBalance = serverAvailable ?? Math.max(0, wonBalance - pendingWithdrawals);

  useEffect(() => {
    if (isOpen) {
      loadBankOptions();
      loadPendingWithdrawals();
      loadAvailableBalance();
      resetForm();
    }
  }, [isOpen]);

  const resetForm = () => {
    setStep('amount');
    setAmount('');
    setSelectedBank('');
    setAccountNumber('');
    setAccountName('');
    setError(null);
  };

  const loadBankOptions = async () => {
    setIsLoading(true);
    try {
      const { data, error } = await supabase
        .from('withdrawal_bank_options')
        .select('*')
        .eq('is_active', true)
        .order('display_order', { ascending: true });

      if (error) throw error;
      setBanks(data || []);
    } catch (error) {
      console.error('Error loading bank options:', error);
      setError('Failed to load bank options');
    } finally {
      setIsLoading(false);
    }
  };

  const loadPendingWithdrawals = async () => {
    // Still read directly, and legitimately: db/20-post/007 gives `authenticated`
    // a SELECT policy scoped to the caller's own rows, so this is plain data
    // access. It is shown as "pending" for context; it does not decide anything.
    try {
      const { data } = await supabase
        .from('withdrawal_requests')
        .select('amount')
        .eq('telegram_user_id', telegramUserId)
        .in('status', ['pending', 'processing']);

      const total = data?.reduce((sum, w) => sum + Number(w.amount), 0) || 0;
      setPendingWithdrawals(total);
    } catch (error) {
      console.error('Error loading pending withdrawals:', error);
    }
  };

  const loadAvailableBalance = async () => {
    try {
      const token = await getAccessToken();
      if (!token) return;

      const res = await fetch(`${API}/functions/v1/withdrawals/available`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!res.ok) return;

      const body = await res.json();
      if (typeof body.available === 'number') setServerAvailable(body.available);
    } catch (error) {
      console.error('Error loading available balance:', error);
    }
  };

  const handleAmountNext = () => {
    const amountNum = parseFloat(amount);
    if (isNaN(amountNum) || amountNum <= 0) {
      setError('Please enter a valid amount');
      return;
    }
    if (amountNum < MIN_WITHDRAWAL_ETB) {
      setError(`Minimum withdrawal amount is ${MIN_WITHDRAWAL_ETB} ETB`);
      return;
    }
    if (amountNum > availableBalance) {
      setError(`Insufficient balance. Available: ${availableBalance} ETB`);
      return;
    }
    setError(null);
    setStep('bank');
  };

  const handleBankNext = () => {
    if (!selectedBank) {
      setError('Please select a bank');
      return;
    }
    setError(null);
    setStep('account');
  };

  const handleAccountNext = () => {
    if (accountNumber.length < 8) {
      setError('Please enter a valid account number');
      return;
    }
    setError(null);
    setStep('name');
  };

  const handleNameNext = () => {
    if (accountName.trim().length < 3) {
      setError('Please enter a valid account holder name');
      return;
    }
    setError(null);
    setStep('confirm');
  };

  const handleSubmit = async () => {
    setIsSubmitting(true);
    setError(null);

    try {
      const token = await getAccessToken();
      if (!token) {
        setError('Your session has expired. Close this and open the app again.');
        return;
      }

      // telegram_user_id is NOT sent. The route takes it from the token, and
      // would ignore it here -- there is a test asserting exactly that.
      const res = await fetch(`${API}/functions/v1/withdrawals/request`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          bankOptionId: selectedBank,
          amount: parseFloat(amount),
          accountNumber: accountNumber.trim(),
          accountName: accountName.trim(),
        }),
      });

      const body = await res.json().catch(() => ({}));

      if (!res.ok) {
        // INSUFFICIENT_BALANCE is a 409 carrying the real numbers, so the form
        // can say what actually changed rather than repeating a stale figure.
        // Most often the cause is the player's own earlier request still sitting
        // in the queue, which they cannot see from this screen.
        if (body.error_code === 'INSUFFICIENT_BALANCE') {
          setServerAvailable(body.available ?? 0);
          setPendingWithdrawals(body.already_pending ?? 0);
          setError(
            `Not enough available balance. You can withdraw ${body.available ?? 0} ETB` +
              (body.already_pending
                ? ` — ${body.already_pending} ETB is already awaiting payout.`
                : '.'),
          );
          setStep('amount');
          return;
        }

        setError(body.error || 'Failed to submit withdrawal request');
        return;
      }

      onSuccess();
      onClose();
      resetForm();
    } catch (error) {
      console.error('Error submitting withdrawal:', error);
      setError(error instanceof Error ? error.message : 'Failed to submit withdrawal request');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleBack = () => {
    setError(null);
    if (step === 'bank') setStep('amount');
    else if (step === 'account') setStep('bank');
    else if (step === 'name') setStep('account');
    else if (step === 'confirm') setStep('name');
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-2xl shadow-2xl max-w-lg w-full max-h-[90vh] overflow-hidden flex flex-col">
        <div className="flex items-center justify-between p-6 border-b border-gray-200 dark:border-gray-700">
          <h2 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center gap-2">
            <Building2 className="w-6 h-6 text-yellow-600" />
            Bank Withdrawal
          </h2>
          <button
            onClick={onClose}
            className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            <X className="w-5 h-5 text-gray-500" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-6">
          {error && (
            <div className="mb-4 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-700 rounded-lg p-4 flex items-start gap-3">
              <AlertCircle className="w-5 h-5 text-red-600 dark:text-red-400 flex-shrink-0 mt-0.5" />
              <p className="text-sm text-red-800 dark:text-red-300">{error}</p>
            </div>
          )}

          <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-700 rounded-lg p-4 mb-6">
            <div className="space-y-2 text-sm">
              <div className="flex justify-between">
                <span className="text-gray-700 dark:text-gray-300">Won Balance:</span>
                <span className="font-bold text-gray-900 dark:text-white">{wonBalance} ETB</span>
              </div>
              {pendingWithdrawals > 0 && (
                <div className="flex justify-between">
                  <span className="text-gray-700 dark:text-gray-300">Pending Withdrawals:</span>
                  <span className="font-bold text-yellow-600">{pendingWithdrawals} ETB</span>
                </div>
              )}
              <div className="flex justify-between pt-2 border-t border-blue-300 dark:border-blue-600">
                <span className="text-gray-700 dark:text-gray-300">Available to Withdraw:</span>
                <span className="font-bold text-green-600 dark:text-green-400">{availableBalance} ETB</span>
              </div>
            </div>
          </div>

          {availableBalance < 100 ? (
            <div className="text-center py-8">
              <AlertCircle className="w-16 h-16 text-yellow-500 mx-auto mb-4" />
              <p className="text-gray-700 dark:text-gray-300 text-lg font-semibold mb-2">
                Insufficient Balance
              </p>
              <p className="text-gray-500 dark:text-gray-400 text-sm">
                Minimum withdrawal amount is 100 ETB
              </p>
              <p className="text-gray-500 dark:text-gray-400 text-sm mt-2">
                Keep playing to increase your withdrawable balance!
              </p>
            </div>
          ) : (
            <>
              {step === 'amount' && (
                <div className="space-y-4">
                  <div>
                    <label className="block text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
                      Withdrawal Amount (ETB)
                    </label>
                    <input
                      type="number"
                      value={amount}
                      onChange={(e) => setAmount(e.target.value)}
                      placeholder="Enter amount (min: 100 ETB)"
                      className="w-full px-4 py-3 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-yellow-500 focus:border-transparent outline-none transition bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                      min="100"
                      max={availableBalance}
                      step="10"
                    />
                    <p className="text-xs text-gray-500 dark:text-gray-400 mt-2">
                      Minimum: 100 ETB • Maximum: {availableBalance} ETB
                    </p>
                  </div>
                </div>
              )}

              {step === 'bank' && (
                <div className="space-y-4">
                  <p className="text-gray-600 dark:text-gray-300 mb-4">
                    Select your bank:
                  </p>
                  {banks.map((bank) => (
                    <button
                      key={bank.id}
                      onClick={() => setSelectedBank(bank.id)}
                      className={`w-full text-left border-2 rounded-xl p-4 transition-all ${
                        selectedBank === bank.id
                          ? 'border-yellow-500 bg-yellow-50 dark:bg-yellow-900/20'
                          : 'border-gray-200 dark:border-gray-600 hover:border-yellow-400 bg-white dark:bg-gray-700'
                      }`}
                    >
                      <div className="flex items-center justify-between">
                        <div className="flex items-center gap-3">
                          <div className={`p-3 rounded-lg ${
                            selectedBank === bank.id
                              ? 'bg-yellow-100 dark:bg-yellow-900/40'
                              : 'bg-gray-100 dark:bg-gray-600'
                          }`}>
                            <Building2 className={`w-6 h-6 ${
                              selectedBank === bank.id
                                ? 'text-yellow-600'
                                : 'text-gray-600 dark:text-gray-300'
                            }`} />
                          </div>
                          <span className="font-bold text-gray-900 dark:text-white">
                            {bank.bank_name}
                          </span>
                        </div>
                        {selectedBank === bank.id && (
                          <CheckCircle className="w-6 h-6 text-yellow-600" />
                        )}
                      </div>
                    </button>
                  ))}
                </div>
              )}

              {step === 'account' && (
                <div className="space-y-4">
                  <div>
                    <label className="block text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
                      Account Number
                    </label>
                    <input
                      type="text"
                      value={accountNumber}
                      onChange={(e) => setAccountNumber(e.target.value)}
                      placeholder="Enter your account number"
                      className="w-full px-4 py-3 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-yellow-500 focus:border-transparent outline-none transition bg-white dark:bg-gray-700 text-gray-900 dark:text-white font-mono"
                    />
                  </div>
                </div>
              )}

              {step === 'name' && (
                <div className="space-y-4">
                  <div>
                    <label className="block text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
                      Account Holder Name
                    </label>
                    <input
                      type="text"
                      value={accountName}
                      onChange={(e) => setAccountName(e.target.value)}
                      placeholder="Enter account holder name"
                      className="w-full px-4 py-3 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-yellow-500 focus:border-transparent outline-none transition bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
                    />
                  </div>
                </div>
              )}

              {step === 'confirm' && (
                <div className="space-y-4">
                  <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-4 space-y-3">
                    <div className="flex justify-between">
                      <span className="text-gray-600 dark:text-gray-400">Amount:</span>
                      <span className="font-bold text-gray-900 dark:text-white">{amount} ETB</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600 dark:text-gray-400">Bank:</span>
                      <span className="font-bold text-gray-900 dark:text-white">
                        {banks.find((b) => b.id === selectedBank)?.bank_name ?? ''}
                      </span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600 dark:text-gray-400">Account:</span>
                      <span className="font-bold text-gray-900 dark:text-white font-mono">{accountNumber}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600 dark:text-gray-400">Name:</span>
                      <span className="font-bold text-gray-900 dark:text-white">{accountName}</span>
                    </div>
                  </div>

                  <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-700 rounded-lg p-4">
                    <p className="text-sm text-yellow-800 dark:text-yellow-300">
                      <strong>Processing Time:</strong> Withdrawals are processed manually by admin, usually within 24 hours.
                    </p>
                  </div>
                </div>
              )}
            </>
          )}
        </div>

        <div className="border-t border-gray-200 dark:border-gray-700 p-6">
          {availableBalance >= 100 && (
            <div className="flex gap-3">
              {step !== 'amount' && (
                <button
                  onClick={handleBack}
                  disabled={isSubmitting}
                  className="flex-1 bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 text-gray-800 dark:text-white font-semibold py-3 px-6 rounded-lg transition-colors disabled:opacity-50"
                >
                  Back
                </button>
              )}
              <button
                onClick={() => {
                  if (step === 'amount') handleAmountNext();
                  else if (step === 'bank') handleBankNext();
                  else if (step === 'account') handleAccountNext();
                  else if (step === 'name') handleNameNext();
                  else if (step === 'confirm') handleSubmit();
                }}
                disabled={isSubmitting || (step === 'amount' && !amount) || (step === 'bank' && !selectedBank) || (step === 'account' && !accountNumber) || (step === 'name' && !accountName)}
                className="flex-1 bg-yellow-600 hover:bg-yellow-700 text-white font-semibold py-3 px-6 rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {isSubmitting ? 'Submitting...' : step === 'confirm' ? 'Submit Withdrawal' : 'Next'}
              </button>
            </div>
          )}
          {availableBalance < 100 && (
            <button
              onClick={onClose}
              className="w-full bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 text-gray-800 dark:text-white font-semibold py-3 px-6 rounded-lg transition-colors"
            >
              Close
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
