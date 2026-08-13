import { useState, useEffect } from 'react';
import { supabase } from '../lib/supabase';
import { getAccessToken } from '../lib/auth';
import { X, Building2, Copy, Check } from 'lucide-react';

interface BankOption {
  id: string;
  bank_name: string;
  account_number: string;
  account_name: string;
  instructions: string;
  is_active: boolean;
  display_order: number;
}

interface BankDepositModalProps {
  isOpen: boolean;
  onClose: () => void;
  telegramUserId: number;
}

export function BankDepositModal({ isOpen, onClose }: BankDepositModalProps) {
  const [banks, setBanks] = useState<BankOption[]>([]);
  const [selectedBank, setSelectedBank] = useState<BankOption | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [copiedField, setCopiedField] = useState<string | null>(null);
  const [supportContact, setSupportContact] = useState<string>('');

  useEffect(() => {
    if (isOpen) {
      loadBankOptions();
      loadSupportContact();
    }
  }, [isOpen]);

  const loadBankOptions = async () => {
    setIsLoading(true);
    try {
      const { data, error } = await supabase
        .from('bank_options')
        .select('*')
        .eq('is_active', true)
        .order('display_order', { ascending: true });

      if (error) throw error;
      setBanks(data || []);
    } catch (error) {
      console.error('Error loading bank options:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const loadSupportContact = async () => {
    try {
      const { data } = await supabase
        .from('settings')
        .select('value')
        .eq('id', 'support_contact')
        .maybeSingle();

      if (data) {
        setSupportContact(data.value);
      }
    } catch (error) {
      console.error('Error loading support contact:', error);
    }
  };

  const [reference, setReference] = useState('');
  const [claimAmount, setClaimAmount] = useState('');
  const [claimBusy, setClaimBusy] = useState(false);
  const [claimError, setClaimError] = useState<string | null>(null);
  const [claimOk, setClaimOk] = useState(false);

  const submitClaim = async () => {
    if (!selectedBank) return;
    setClaimBusy(true);
    setClaimError(null);
    setClaimOk(false);

    try {
      const token = await getAccessToken();
      const res = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/deposits/claim`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          bankOptionId: selectedBank.id,
          referenceNumber: reference.trim(),
          claimedAmount: Number(claimAmount),
        }),
      });

      const body = await res.json().catch(() => ({}));

      if (res.ok && body.success) {
        setClaimOk(true);
        setReference('');
        setClaimAmount('');
        return;
      }

      // 409 is the duplicate-reference case and is the one a player can act on:
      // they have already submitted this transfer.
      setClaimError(body.error ?? `Could not submit (${res.status})`);
    } catch {
      setClaimError('Could not reach the server. Check your connection and try again.');
    } finally {
      setClaimBusy(false);
    }
  };

  const handleCopy = (text: string, field: string) => {
    navigator.clipboard.writeText(text);
    setCopiedField(field);
    setTimeout(() => setCopiedField(null), 2000);
  };

  const handleBackToList = () => {
    setSelectedBank(null);
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-2xl shadow-2xl max-w-2xl w-full max-h-[90vh] overflow-hidden flex flex-col">
        <div className="flex items-center justify-between p-6 border-b border-gray-200 dark:border-gray-700">
          <h2 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center gap-2">
            <Building2 className="w-6 h-6 text-blue-600" />
            Bank Deposit
          </h2>
          <button
            onClick={onClose}
            className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          >
            <X className="w-5 h-5 text-gray-500" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-6">
          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600"></div>
            </div>
          ) : selectedBank ? (
            <div className="space-y-6">
              <button
                onClick={handleBackToList}
                className="text-blue-600 hover:text-blue-700 font-medium text-sm flex items-center gap-1"
              >
                ← Back to bank list
              </button>

              <div className="bg-blue-50 dark:bg-blue-900/20 border-2 border-blue-200 dark:border-blue-700 rounded-xl p-6">
                <h3 className="text-xl font-bold text-gray-900 dark:text-white mb-4">
                  {selectedBank.bank_name}
                </h3>

                <div className="space-y-4">
                  <div>
                    <label className="block text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
                      Account Number
                    </label>
                    <div className="flex items-center gap-2">
                      <div className="flex-1 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600 rounded-lg px-4 py-3 font-mono text-lg font-bold text-gray-900 dark:text-white">
                        {selectedBank.account_number}
                      </div>
                      <button
                        onClick={() => handleCopy(selectedBank.account_number, 'account')}
                        className="p-3 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors"
                      >
                        {copiedField === 'account' ? (
                          <Check className="w-5 h-5" />
                        ) : (
                          <Copy className="w-5 h-5" />
                        )}
                      </button>
                    </div>
                  </div>

                  <div>
                    <label className="block text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
                      Account Name
                    </label>
                    <div className="flex items-center gap-2">
                      <div className="flex-1 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600 rounded-lg px-4 py-3 font-semibold text-gray-900 dark:text-white">
                        {selectedBank.account_name}
                      </div>
                      <button
                        onClick={() => handleCopy(selectedBank.account_name, 'name')}
                        className="p-3 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors"
                      >
                        {copiedField === 'name' ? (
                          <Check className="w-5 h-5" />
                        ) : (
                          <Copy className="w-5 h-5" />
                        )}
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div className="bg-yellow-50 dark:bg-yellow-900/20 border-l-4 border-yellow-400 p-4 rounded">
                <h4 className="font-semibold text-yellow-800 dark:text-yellow-300 mb-2">Instructions</h4>
                <div className="text-sm text-yellow-700 dark:text-yellow-400 whitespace-pre-line">
                  {selectedBank.instructions}
                </div>
              </div>

              {supportContact && (
                <div className="bg-gray-50 dark:bg-gray-700/50 border border-gray-200 dark:border-gray-600 rounded-lg p-4">
                  <div className="text-sm text-gray-700 dark:text-gray-300 whitespace-pre-line">
                    {supportContact}
                  </div>
                </div>
              )}

              {/* THE CLAIM FORM.
                  This modal was display-only: it showed where to send money and
                  stopped. The note it replaces told players to "send the bank SMS
                  confirmation to the Telegram bot", which describes the upstream
                  SMS-matching flow -- there is no bot webhook on this
                  infrastructure, so nothing was listening and no deposit could
                  ever be credited.

                  Posts to /deposits/claim, which derives the player from the
                  token and the bank name from our own row. The player supplies
                  only the reference and the amount. */}
              <div className="border border-gray-200 dark:border-gray-600 rounded-lg p-4 space-y-3">
                <h4 className="font-semibold text-gray-900 dark:text-gray-100">After you have sent the money</h4>
                <p className="text-sm text-gray-600 dark:text-gray-400">
                  Enter the transaction number from your {selectedBank.bank_name} SMS. We check the
                  account and credit you, usually within a few minutes.
                </p>

                {/* STACKED ON A PHONE, side by side only when there is room.
                    This was a single `flex gap-2` row, and the Amount field was
                    CLIPPED OFF THE RIGHT EDGE on a real device -- seen in a
                    Telegram Mini App screenshot, not in a desktop browser.

                    The cause is a flex default rather than a missing width: a
                    flex item is `min-width: auto`, so `flex-1` on the first
                    input will not shrink below its own placeholder, and
                    "Transaction number" is long. The row therefore overflows and
                    pushes the fixed `w-28` field out of the card.

                    `min-w-0` alone would stop the overflow by squeezing the
                    reference field instead, which is the wrong trade: a
                    transaction number is the longer of the two values and the
                    one that must be read back to check it. So they stack. */}
                <div className="flex flex-col gap-2 sm:flex-row">
                  <input
                    type="text"
                    value={reference}
                    onChange={(e) => setReference(e.target.value)}
                    placeholder="Transaction number"
                    className="min-w-0 flex-1 px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg text-sm dark:bg-gray-700 dark:text-gray-100"
                  />
                  <input
                    type="number"
                    inputMode="numeric"
                    value={claimAmount}
                    onChange={(e) => setClaimAmount(e.target.value)}
                    placeholder="Amount"
                    className="w-full sm:w-28 px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg text-sm dark:bg-gray-700 dark:text-gray-100"
                  />
                </div>

                {claimError && (
                  <p className="text-sm text-red-600 dark:text-red-400">{claimError}</p>
                )}
                {claimOk && (
                  <p className="text-sm text-green-700 dark:text-green-400">
                    Submitted. We will credit your account once we confirm the transfer.
                  </p>
                )}

                <button
                  onClick={submitClaim}
                  disabled={claimBusy || !reference.trim() || !claimAmount.trim()}
                  className="w-full py-2 px-4 rounded-lg font-semibold bg-blue-600 hover:bg-blue-700 text-white disabled:opacity-50"
                >
                  {claimBusy ? 'Submitting…' : 'I have sent the money'}
                </button>
              </div>
            </div>
          ) : banks.length === 0 ? (
            <div className="text-center py-12">
              <Building2 className="w-16 h-16 text-gray-300 dark:text-gray-600 mx-auto mb-4" />
              <p className="text-gray-500 dark:text-gray-400 text-lg">
                No bank options available at the moment
              </p>
              <p className="text-gray-400 dark:text-gray-500 text-sm mt-2">
                Please contact support for assistance
              </p>
            </div>
          ) : (
            <div className="space-y-4">
              <p className="text-gray-600 dark:text-gray-300 mb-4">
                Select a bank to view deposit instructions:
              </p>
              {banks.map((bank) => (
                <button
                  key={bank.id}
                  onClick={() => setSelectedBank(bank)}
                  className="w-full text-left bg-white dark:bg-gray-700 border-2 border-gray-200 dark:border-gray-600 hover:border-blue-500 dark:hover:border-blue-500 rounded-xl p-4 transition-all hover:shadow-lg"
                >
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-3">
                      <div className="bg-blue-100 dark:bg-blue-900/30 p-3 rounded-lg">
                        <Building2 className="w-6 h-6 text-blue-600 dark:text-blue-400" />
                      </div>
                      <div>
                        <h3 className="font-bold text-gray-900 dark:text-white text-lg">
                          {bank.bank_name}
                        </h3>
                        <p className="text-sm text-gray-500 dark:text-gray-400">
                          Click to view details
                        </p>
                      </div>
                    </div>
                    <div className="text-gray-400">→</div>
                  </div>
                </button>
              ))}
            </div>
          )}
        </div>

        <div className="border-t border-gray-200 dark:border-gray-700 p-6">
          <button
            onClick={selectedBank ? handleBackToList : onClose}
            className="w-full bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 text-gray-800 dark:text-white font-semibold py-3 px-6 rounded-lg transition-colors"
          >
            {selectedBank ? 'Back to Bank List' : 'Close'}
          </button>
        </div>
      </div>
    </div>
  );
}
