import { useEffect, useState, useRef, useCallback } from 'react';
import { supabase, Game, Player } from '../lib/supabase';
import { getAccessToken } from '../lib/auth';
import { BingoCard } from './BingoCard';
import { getBingoLetter, canClaimBingo } from '../utils/bingoUtils';
import { Trophy, Eye } from 'lucide-react';
import { useConnectionManager } from '../hooks/useConnectionManager';
import { formatBirr, CURRENCY_LABEL } from '../utils/formatBalance';

interface GameRoomProps {
  gameId: string;
  playerId: string | null;
  onReturnToLobby?: () => void;
  /**
   * Whether to offer the MANUAL exit. Separate from onReturnToLobby, and that
   * separation is the whole point.
   *
   * onReturnToLobby does two unrelated jobs: it backs the spectator's button,
   * and it is what returns EVERYBODY to the lobby automatically when a game
   * finishes. Withholding the callback to hide the button therefore also
   * removed the automatic return -- so a player who reached "Game Over" was
   * stranded there with no way out. Shipped in #132 and found in dev within a
   * day.
   *
   * The callback is now always supplied. This decides only whether a button is
   * drawn.
   */
  canExitEarly?: boolean;
}

export function GameRoom({
  gameId,
  playerId,
  onReturnToLobby,
  canExitEarly = true,
}: GameRoomProps) {
  const [game, setGame] = useState<Game | null>(null);
  const [players, setPlayers] = useState<Player[]>([]);
  const [currentPlayer, setCurrentPlayer] = useState<Player | null>(null);
  const [cachedWinners, setCachedWinners] = useState<Player[]>([]);
  const [bingoLoading, setBingoLoading] = useState(false);
  const [bingoError, setBingoError] = useState<string | null>(null);
  const [isDarkMode, setIsDarkMode] = useState(() => {
    const saved = localStorage.getItem('darkMode');
    return saved === 'false' ? false : true;
  });
  const [returnCountdown, setReturnCountdown] = useState<number | null>(null);
  const onReturnToLobbyRef = useRef(onReturnToLobby);
  const bingoClaimAttemptRef = useRef<number>(0);
  const bingoDebouncerRef = useRef<NodeJS.Timeout | null>(null);
  const bingoClaimIdRef = useRef<string | null>(null);
  const pollIntervalRef = useRef<NodeJS.Timeout | null>(null);
  const countdownIntervalRef = useRef<NodeJS.Timeout | null>(null);
  const [localMarkedCells, setLocalMarkedCells] = useState<boolean[][]>(() =>
    Array(5).fill(null).map(() => Array(5).fill(false))
  );
  const hasInitializedMarks = useRef(false);

  const { isReconnecting } = useConnectionManager(
    `game-health:${gameId}`,
    {
      heartbeatInterval: 30000,
      onReconnect: () => {
        loadGameData();
      }
    }
  );

  useEffect(() => {
    localStorage.setItem('darkMode', String(isDarkMode));
  }, [isDarkMode]);

  useEffect(() => {
    const handleStorageChange = () => {
      const saved = localStorage.getItem('darkMode');
      setIsDarkMode(saved === 'true');
    };

    window.addEventListener('storage', handleStorageChange);
    return () => window.removeEventListener('storage', handleStorageChange);
  }, []);

  // Update ref when callback changes
  useEffect(() => {
    onReturnToLobbyRef.current = onReturnToLobby;
  }, [onReturnToLobby]);

  // Cache winners when game finishes
  useEffect(() => {
    if (game?.status === 'finished' && game.winner_ids && game.winner_ids.length > 0) {
      const winnerPlayers = players.filter(p => game.winner_ids.includes(p.id));
      if (winnerPlayers.length > 0 && cachedWinners.length === 0) {
        setCachedWinners(winnerPlayers);
      }
    }
  }, [game?.status, game?.winner_ids, players, cachedWinners.length]);

  // Server-synchronized countdown for returning to lobby
  useEffect(() => {
    if (game?.status === 'finished' && game.return_to_lobby_at) {
      // Captured into a const, because the narrowing from the `if` above does not
      // survive into this closure -- `return_to_lobby_at` is `string | null`, and
      // TypeScript must assume `game` could change before the interval fires, so
      // inside here it is nullable again and `new Date(string | null)` matches no
      // overload.
      //
      // That assumption is not paranoia: this runs on an interval, and reading
      // the field afresh each tick would genuinely be reading it from a later
      // `game`. Capturing the value the countdown was STARTED for is both what
      // types correctly and what the code means.
      const returnToLobbyAt = game.return_to_lobby_at;

      const updateCountdown = () => {
        const returnTime = new Date(returnToLobbyAt).getTime();
        const now = Date.now();
        const remainingMs = returnTime - now;
        const remainingSeconds = Math.ceil(remainingMs / 1000);

        if (remainingSeconds <= 0) {
          setReturnCountdown(0);
          if (countdownIntervalRef.current) {
            clearInterval(countdownIntervalRef.current);
            countdownIntervalRef.current = null;
          }
          if (onReturnToLobbyRef.current) {
            onReturnToLobbyRef.current();
          }
        } else {
          setReturnCountdown(remainingSeconds);
        }
      };

      updateCountdown();
      countdownIntervalRef.current = setInterval(updateCountdown, 100);

      return () => {
        if (countdownIntervalRef.current) {
          clearInterval(countdownIntervalRef.current);
          countdownIntervalRef.current = null;
        }
      };
    } else if (game?.status === 'finished' && !game.return_to_lobby_at) {
      const fallbackTimer = setTimeout(() => {
        if (onReturnToLobbyRef.current) {
          onReturnToLobbyRef.current();
        }
      }, 7000);

      return () => clearTimeout(fallbackTimer);
    }
  }, [game?.status, game?.return_to_lobby_at]);

  useEffect(() => {
    loadGameData();

    const gameChannel = supabase
      .channel(`game:${gameId}`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'games', filter: `id=eq.${gameId}` },
        (payload) => {
          if (payload.eventType === 'UPDATE') {
            setGame(payload.new as Game);
          }
        }
      )
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'players', filter: `game_id=eq.${gameId}` },
        () => {
          loadPlayers();
        }
      )
      .subscribe();

    pollIntervalRef.current = setInterval(() => {
      if (!document.hidden) {
        loadGameData();
      }
    }, 3000);

    return () => {
      supabase.removeChannel(gameChannel);
      if (pollIntervalRef.current) {
        clearInterval(pollIntervalRef.current);
      }
    };
  }, [gameId]);


  const loadGameData = async () => {
    const { data: gameData } = await supabase
      .from('games')
      .select('*')
      .eq('id', gameId)
      .maybeSingle();

    if (gameData) {
      setGame(gameData);

      // NOTHING HERE. This used to POST /functions/v1/force-finish-game when it
      // saw 75 called numbers on a game still marked `playing`.
      //
      // Two things were wrong with it. The route is a 404 -- an inherited Deno
      // name the rebuilt service never implemented -- so the "fix" never ran. And
      // it was client-driven game logic, which is exactly what moving the loop
      // into the ticker existed to remove: a game that only finishes when
      // somebody has the tab open is the failure mode AGENTS.md warns against.
      //
      // game_tick() already owns it, and has since db/20-post/002:
      //
      //   -- Exhausted the board: finish rather than spin.
      //   IF coalesce(array_length(v_game.called_numbers, 1), 0) >= p_max_numbers
      //     SET status = 'finished', finished_at = now()
      //
      // with p_max_numbers defaulting to 75, evaluated once a second by the
      // ticker whether or not any browser is watching. Setting `finished` there
      // also fires payout_winners(), which this client call never would have.
      //
      // So the route was not worth building: the correct fix was deleting the
      // caller.
    }

    await loadPlayers();
  };

  const loadPlayers = async () => {
    const { data: playersData } = await supabase
      .from('players')
      .select('*')
      .eq('game_id', gameId)
      .order('joined_at', { ascending: true });

    if (playersData) {
      setPlayers(playersData);
      if (playerId) {
        const player = playersData.find(p => p.id === playerId);
        if (player) {
          setCurrentPlayer(player);
          // Only initialize marks once from database on first load
          if (!hasInitializedMarks.current && player.marked_cells) {
            setLocalMarkedCells(player.marked_cells);
            hasInitializedMarks.current = true;
          }
        }
      }
    }
  };

  const handleCellClick = useCallback((col: number, row: number) => {
    if (!currentPlayer || !playerId || game?.status !== 'playing' || currentPlayer.is_disqualified) return;

    // Always use local state for marking - no fallback to database
    const newMarkedCells = localMarkedCells.map((column, colIdx) =>
      colIdx === col ? column.map((cell, rowIdx) => (rowIdx === row ? !cell : cell)) : column
    );

    setLocalMarkedCells(newMarkedCells);
  }, [currentPlayer, playerId, game?.status, localMarkedCells]);

  // Would the server accept a claim right now?
  //
  // A refused claim is not a no-op: atomic_claim_bingo sets is_disqualified on
  // the player row, so a mis-tap ends the game for somebody who paid a stake to
  // enter it, with no refund -- refund_player_stake only fires on release, which
  // is impossible once the game has started. canClaimBingo mirrors
  // check_player_win exactly, including the rule that the line must be completed
  // BY the current number, and is tested against the same vectors as
  // db/test/game_integrity_test.sql so the two cannot drift apart.
  const claimable = canClaimBingo(
    currentPlayer?.card_numbers as number[][] | undefined,
    game?.called_numbers,
    game?.current_number,
  );

  const handleBingoClick = async () => {
    if (!currentPlayer || !playerId || game?.status !== 'playing' || currentPlayer.is_disqualified) return;

    // Checked here as well as on the button's `disabled`. That is a UI state;
    // this is the one a stray synthetic event or a double-tap landing between
    // renders cannot get round.
    if (!claimable) return;

    if (bingoLoading) return;

    if (bingoDebouncerRef.current) {
      clearTimeout(bingoDebouncerRef.current);
    }

    const claimId = `${playerId}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;

    if (bingoClaimIdRef.current === claimId) {
      return;
    }
    bingoClaimIdRef.current = claimId;

    setBingoError(null);
    setBingoLoading(true);
    bingoClaimAttemptRef.current += 1;

    const triggerHaptic = () => {
      if (navigator.vibrate) {
        navigator.vibrate(50);
      }
    };

    const claimBingoWithRetry = async (attempt: number = 1): Promise<boolean> => {
      const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
      const maxAttempts = 3;

      // The PLAYER'S token, not the anon key.
      //
      // /claim-bingo now requires a proven identity and checks that the player
      // row being claimed for actually belongs to it. Previously the anon key was
      // sent and playerId came from the body, so any caller could submit a claim
      // on behalf of any player -- which cannot invent a win, since the database
      // validates the pattern, but can spend a rival's single claim and get them
      // disqualified for a losing one.
      const token = await getAccessToken();

      try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 5000);

        const response = await fetch(`${supabaseUrl}/functions/v1/claim-bingo`, {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ playerId, claimId }),
          signal: controller.signal,
        });

        clearTimeout(timeoutId);

        const result = await response.json();

        if (!response.ok) {
          if (result.duplicate) {
            return true;
          }
          if (attempt < maxAttempts) {
            const backoffDelay = Math.min(500 * Math.pow(2, attempt - 1), 2000);
            await new Promise(resolve => setTimeout(resolve, backoffDelay));
            return claimBingoWithRetry(attempt + 1);
          }
          throw new Error(result.error || 'Failed to claim BINGO');
        }

        if (result.disqualified) {
          triggerHaptic();
          const updatedPlayer = { ...currentPlayer, is_disqualified: true };
          setCurrentPlayer(updatedPlayer);
          setPlayers(prev => prev.map(p => p.id === playerId ? updatedPlayer : p));
          setBingoError('False BINGO - disqualified');
        } else if (result.isWinner) {
          triggerHaptic();
        }

        return true;
      } catch (error) {
        const errorMsg = error instanceof Error ? error.message : 'Network error';
        if (attempt < maxAttempts) {
          const backoffDelay = Math.min(500 * Math.pow(2, attempt - 1), 2000);
          await new Promise(resolve => setTimeout(resolve, backoffDelay));
          return claimBingoWithRetry(attempt + 1);
        }
        setBingoError(errorMsg);
        console.error('Failed to claim bingo after retries:', error);
        return false;
      }
    };

    try {
      await claimBingoWithRetry();
    } finally {
      setBingoLoading(false);
      bingoClaimIdRef.current = null;

      bingoDebouncerRef.current = setTimeout(() => {
        setBingoError(null);
      }, 3000);
    }
  };



  if (!game) {
    return (
      <div className={`min-h-screen flex items-center justify-center transition-colors duration-300 ${isDarkMode ? 'bg-gradient-to-br from-gray-900 to-gray-800' : 'bg-gradient-to-br from-blue-50 to-indigo-100'}`}>
        <div className={isDarkMode ? 'text-gray-300' : 'text-gray-600'}>Loading game...</div>
      </div>
    );
  }

  const isSpectator = !playerId || !currentPlayer;
  const winners = cachedWinners.length > 0
    ? cachedWinners
    : (game.winner_ids && game.winner_ids.length > 0
        ? players.filter(p => game.winner_ids.includes(p.id))
        : []);

  const getBingoColumn = (num: number): number => {
    if (num <= 15) return 0;
    if (num <= 30) return 1;
    if (num <= 45) return 2;
    if (num <= 60) return 3;
    return 4;
  };

  const getBingoColumnColor = (num: number): { bg: string; text: string } => {
    if (num <= 15) return { bg: 'bg-yellow-500', text: 'text-gray-900' };
    if (num <= 30) return { bg: 'bg-green-600', text: 'text-white' };
    if (num <= 45) return { bg: 'bg-blue-600', text: 'text-white' };
    if (num <= 60) return { bg: 'bg-red-600', text: 'text-white' };
    return { bg: 'bg-blue-700', text: 'text-white' };
  };

  const generateBoardNumbers = () => {
    const columns = [[], [], [], [], []] as number[][];
    for (let i = 1; i <= 75; i++) {
      const col = getBingoColumn(i);
      columns[col].push(i);
    }
    return columns;
  };

  const boardColumns = generateBoardNumbers();

  return (
    <div className={`min-h-screen p-2 sm:p-4 transition-colors duration-300 ${isDarkMode ? 'bg-gradient-to-br from-gray-900 to-gray-800' : 'bg-gradient-to-br from-blue-50 to-blue-100'}`}>
      <div className="max-w-6xl mx-auto">
        {isReconnecting && (
          <div className="flex items-center justify-center mb-2">
            <div className={`flex items-center gap-2 px-3 py-1.5 rounded-lg ${isDarkMode ? 'bg-yellow-900/40 text-yellow-300' : 'bg-yellow-100 text-yellow-800'}`}>
              <div className="w-3 h-3 border-2 border-current border-t-transparent rounded-full animate-spin"></div>
              <span className="text-xs font-medium">Reconnecting...</span>
            </div>
          </div>
        )}
        <div className="grid grid-cols-4 gap-1.5 sm:gap-2 mb-3">
          <div className={`rounded-lg p-1.5 sm:p-2 text-center transition-colors duration-300 ${isDarkMode ? 'bg-gray-700 border border-gray-600' : 'bg-white'}`}>
            <div className={`text-[10px] sm:text-xs ${isDarkMode ? 'text-gray-300' : 'text-gray-600'}`}>Derash (80%)</div>
            <div className={`text-sm sm:text-lg font-bold ${isDarkMode ? 'text-white' : 'text-gray-900'}`}>{formatBirr(game.winner_prize || Math.floor(game.total_pot * 0.80))}</div>
          </div>
          <div className={`rounded-lg p-1.5 sm:p-2 text-center transition-colors duration-300 ${isDarkMode ? 'bg-gray-700 border border-gray-600' : 'bg-white'}`}>
            <div className={`text-[10px] sm:text-xs ${isDarkMode ? 'text-gray-300' : 'text-gray-600'}`}>Players</div>
            <div className={`text-sm sm:text-lg font-bold ${isDarkMode ? 'text-white' : 'text-gray-900'}`}>{players.length}</div>
          </div>
          <div className={`rounded-lg p-1.5 sm:p-2 text-center transition-colors duration-300 ${isDarkMode ? 'bg-gray-700 border border-gray-600' : 'bg-white'}`}>
            <div className={`text-[10px] sm:text-xs ${isDarkMode ? 'text-gray-300' : 'text-gray-600'}`}>Bet</div>
            <div className={`text-sm sm:text-lg font-bold ${isDarkMode ? 'text-white' : 'text-gray-900'}`}>{formatBirr(game.stake_amount)}</div>
          </div>
          <div className={`rounded-lg p-1.5 sm:p-2 text-center transition-colors duration-300 ${isDarkMode ? 'bg-gray-700 border border-gray-600' : 'bg-white'}`}>
            <div className={`text-[10px] sm:text-xs ${isDarkMode ? 'text-gray-300' : 'text-gray-600'}`}>Call</div>
            <div className={`text-sm sm:text-lg font-bold ${isDarkMode ? 'text-white' : 'text-gray-900'}`}>{game.called_numbers.length}</div>
          </div>
        </div>

          {game.status === 'waiting' && (
            <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3 sm:p-4 text-center">
              <p className="text-yellow-800 font-medium text-sm sm:text-base">
                Waiting for game to start...
              </p>
            </div>
          )}

          {game.status === 'playing' && !isSpectator && currentPlayer.is_disqualified && (
            <div className="bg-red-50 border-2 border-red-300 rounded-xl p-4 sm:p-6 text-center mb-4 sm:mb-6">
              <div className="w-16 h-16 bg-red-100 rounded-full flex items-center justify-center mx-auto mb-3">
                <span className="text-3xl">❌</span>
              </div>
              <h3 className="text-lg sm:text-xl font-bold text-red-900 mb-2">Disqualified - False BINGO</h3>
              <p className="text-red-800 font-medium text-sm sm:text-base mb-1">
                You are now watching this game as a spectator
              </p>
              <p className="text-red-700 text-xs sm:text-sm">
                Wait for this game to finish, then you can join the next round from the lobby!
              </p>
            </div>
          )}

          {game.status === 'playing' && isSpectator && (
            <div className={`border-2 rounded-xl p-4 sm:p-6 text-center mb-4 sm:mb-6 transition-colors duration-300 ${isDarkMode ? 'bg-blue-700/30 border-blue-500' : 'bg-blue-50 border-blue-300'}`}>
              <div className={`w-16 h-16 rounded-full flex items-center justify-center mx-auto mb-3 ${isDarkMode ? 'bg-blue-600/40' : 'bg-blue-100'}`}>
                <Eye className={`w-8 h-8 ${isDarkMode ? 'text-blue-300' : 'text-blue-600'}`} />
              </div>
              <h3 className={`text-lg sm:text-xl font-bold mb-2 ${isDarkMode ? 'text-blue-200' : 'text-blue-900'}`}>Spectator Mode</h3>
              <p className={`text-sm sm:text-base mb-1 ${isDarkMode ? 'text-blue-100' : 'text-blue-800'}`}>
                You are watching this game
              </p>
              <p className={`text-xs sm:text-sm ${isDarkMode ? 'text-blue-200' : 'text-blue-700'}`}>
                You can join the next game from the lobby after this one finishes!
              </p>

              {/* A WAY OUT. Until this existed the only exit from GameRoom was
                  automatic -- onReturnToLobby fires when the game FINISHES.
                  That is fine for a player, who is committed to the round they
                  paid for. It traps a spectator, who tapped "Watch" out of
                  curiosity and then cannot leave until strangers finish playing.

                  Offered only to spectators: a player leaving mid-round would
                  abandon a card they have already been charged for, and
                  `/deselect-card` exists precisely because that has to be a
                  deliberate action with a refund attached, not a back button. */}
              {onReturnToLobby && canExitEarly && (
                <button
                  onClick={onReturnToLobby}
                  className={`mt-3 rounded-lg px-4 py-2 text-sm font-semibold transition-colors ${
                    isDarkMode
                      ? 'bg-blue-600 text-white hover:bg-blue-500'
                      : 'bg-blue-600 text-white hover:bg-blue-700'
                  }`}
                >
                  Back to lobby
                </button>
              )}
            </div>
          )}

          {game.status === 'finished' && (
            <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4 overflow-y-auto">
              <div className="bg-white rounded-2xl shadow-2xl p-6 sm:p-8 max-w-4xl w-full my-8">
                <div className="text-center mb-4 sm:mb-6">
                  <div className="w-20 h-20 sm:w-24 sm:h-24 bg-yellow-100 rounded-full flex items-center justify-center mx-auto mb-3 sm:mb-4">
                    <Trophy className="w-12 h-12 sm:w-16 sm:h-16 text-yellow-500" />
                  </div>
                  <h2 className="text-2xl sm:text-3xl font-bold text-gray-900 mb-2 sm:mb-3">Game Over!</h2>
                  {winners.length === 0 ? (
                    <div className="mb-3 sm:mb-4">
                      <p className="text-xl sm:text-2xl text-gray-600 font-bold mb-2">No Winners</p>
                      <p className="text-base sm:text-lg text-gray-700">
                        All 75 numbers were called but no one completed BINGO
                      </p>
                      <div className="bg-gray-50 border border-gray-200 rounded-lg p-3 sm:p-4 mt-4 inline-block">
                        <div className="text-xs sm:text-sm text-gray-600 mb-1">
                          Total Pot
                        </div>
                        <div className="text-3xl sm:text-4xl font-bold text-gray-600">
                          {formatBirr(game.total_pot)} {CURRENCY_LABEL}
                        </div>
                        <div className="text-xs text-gray-500 mt-1">Stakes refunded to all players</div>
                      </div>
                    </div>
                  ) : winners.length === 1 ? (
                    <>
                      <p className="text-xl sm:text-2xl text-green-600 mb-3 sm:mb-4">
                        <span className="font-bold">{winners[0].name}</span> wins!
                      </p>
                      <div className="bg-green-50 border border-green-200 rounded-lg p-3 sm:p-4 mb-4 sm:mb-6 inline-block">
                        <div className="text-xs sm:text-sm text-gray-600 mb-1">Prize Won</div>
                        <div className="text-3xl sm:text-4xl font-bold text-green-600">
                          {formatBirr(game.winner_prize)} {CURRENCY_LABEL}
                        </div>
                        <div className="text-xs text-gray-500 mt-1">80% of {formatBirr(game.total_pot)} {CURRENCY_LABEL} pot</div>
                      </div>
                    </>
                  ) : (
                    <>
                      <div className="mb-3 sm:mb-4">
                        <p className="text-lg sm:text-xl text-green-600 font-bold mb-2">Multiple Winners!</p>
                        <p className="text-base sm:text-lg text-gray-700">
                          {winners.map(w => w.name).join(', ')}
                        </p>
                      </div>
                      <div className="bg-green-50 border border-green-200 rounded-lg p-3 sm:p-4 mb-4 sm:mb-6 inline-block">
                        <div className="text-xs sm:text-sm text-gray-600 mb-1">Prize Per Winner</div>
                        <div className="text-3xl sm:text-4xl font-bold text-green-600">
                          {formatBirr(game.winner_prize_each)} {CURRENCY_LABEL}
                        </div>
                        <div className="text-xs text-gray-500 mt-1">
                          Prize split {winners.length} ways
                        </div>
                        <div className="text-xs text-gray-500 mt-1">80% of {formatBirr(game.total_pot)} {CURRENCY_LABEL} pot</div>
                      </div>
                    </>
                  )}
                </div>

                {winners.length > 0 && (
                  <div className="space-y-4 sm:space-y-6">
                    {winners.map((winner, winnerIndex) => {
                    const winningPattern = winner.winning_pattern;
                    const isFirstWinner = winnerIndex === 0;
                    const isWinningCell = (col: number, row: number) => {
                      if (!winningPattern || !winningPattern.cells) return false;
                      return winningPattern.cells.some(([c, r]) => c === col && r === row);
                    };

                    // The RETURN TYPE is annotated, and annotating the variable
                    // alone was not enough -- which is the actual mechanism and
                    // worth stating, because the obvious fix looks like it should
                    // work.
                    //
                    // TypeScript's control-flow analysis narrows `lastNumber` to
                    // `null` immediately after `= null`, and it does not track
                    // the assignment inside the forEach callback. So at `return
                    // lastNumber` the NARROWED type is still `null`, the inferred
                    // return type is `null`, and every later
                    // `lastWinningNumber.number` became an access on `never`.
                    // Declaring the variable's type changes nothing about that,
                    // because CFA narrowing wins over the declaration.
                    //
                    // Declaring what the FUNCTION returns is what fixes it.
                    const getLastWinningNumber = (): { col: number; row: number; number: number } | null => {
                      if (!winningPattern || !winningPattern.cells) return null;

                      // Annotated, because `let lastNumber = null` infers the
                      // type `null` and TypeScript does not track the assignment
                      // below across the forEach callback boundary. It therefore
                      // concluded this function ALWAYS returns null, which made
                      // every later `lastWinningNumber.number` / `.col` / `.row`
                      // an access on type `never` -- five type errors pointing at
                      // the use sites rather than at the cause.
                      //
                      // Nothing was broken at runtime; the assignment always
                      // worked. But the wrong type here is what stopped the whole
                      // file from typechecking, and a file that cannot typecheck
                      // hides the next error that IS real.
                      let lastNumber: { col: number; row: number; number: number } | null = null;
                      let lastIndex = -1;

                      winningPattern.cells.forEach(([col, row]) => {
                        if (col === 2 && row === 2) return;

                        const number = winner.card_numbers[col][row];
                        const calledIndex = game.called_numbers.indexOf(number);

                        if (calledIndex > lastIndex) {
                          lastIndex = calledIndex;
                          lastNumber = { col, row, number };
                        }
                      });

                      return lastNumber;
                    };

                    const lastWinningNumber = getLastWinningNumber();
                    const getBingoLetter = (num: number): string => {
                      if (num >= 1 && num <= 15) return 'B';
                      if (num >= 16 && num <= 30) return 'I';
                      if (num >= 31 && num <= 45) return 'N';
                      if (num >= 46 && num <= 60) return 'G';
                      if (num >= 61 && num <= 75) return 'O';
                      return '';
                    };

                    return (
                      <div key={winner.id} className={`border-2 rounded-xl p-4 transition-all duration-300 ${isFirstWinner ? 'winning-card-primary' : 'border-green-300 bg-green-50'}`}>
                        <div className="flex items-center justify-between mb-3">
                          <h3 className="text-lg sm:text-xl font-bold text-gray-900">{winner.name}</h3>
                          {winningPattern && (
                            <div className="bg-yellow-100 border border-yellow-300 rounded-lg px-3 py-1">
                              <span className="text-xs sm:text-sm font-semibold text-yellow-800">
                                {winningPattern.description}
                              </span>
                            </div>
                          )}
                        </div>
                        {lastWinningNumber && (
                          <div className="mb-3 bg-amber-50 border border-amber-300 rounded-lg px-3 py-2">
                            <p className="text-xs sm:text-sm text-amber-900">
                              <span className="font-bold">Winning Number:</span> {getBingoLetter(lastWinningNumber.number)}-{lastWinningNumber.number} 🎯
                            </p>
                          </div>
                        )}
                        <div className="bg-white rounded-xl shadow-lg p-1.5 sm:p-2 lg:p-3">
                          <div className="grid grid-cols-5 gap-0.5 sm:gap-1 lg:gap-1.5 mb-0.5 sm:mb-1 lg:mb-1.5">
                            {['B', 'I', 'N', 'G', 'O'].map((letter, index) => {
                              const headerColors = ['bg-yellow-500', 'bg-green-600', 'bg-blue-600', 'bg-red-600', 'bg-blue-700'];
                              return (
                                <div
                                  key={letter}
                                  className={`h-5 sm:h-7 lg:h-8 flex items-center justify-center ${headerColors[index]} text-white font-bold text-xs sm:text-base lg:text-lg rounded-lg`}
                                >
                                  {letter}
                                </div>
                              );
                            })}
                          </div>
                          <div className="grid grid-cols-5 gap-0.5 sm:gap-1 lg:gap-1.5">
                            {Array.from({ length: 5 }, (_, rowIndex) =>
                              winner.card_numbers.map((column, colIndex) => {
                                const number = column[rowIndex];
                                const isFree = colIndex === 2 && rowIndex === 2;
                                const isWinning = isWinningCell(colIndex, rowIndex);
                                const isCalled = game.called_numbers.includes(number);
                                const isLastWinning = lastWinningNumber &&
                                  lastWinningNumber.col === colIndex &&
                                  lastWinningNumber.row === rowIndex;

                                return (
                                  <div
                                    key={`${colIndex}-${rowIndex}`}
                                    className={`
                                      h-9 sm:h-11 lg:h-12 flex items-center justify-center text-sm sm:text-base lg:text-lg font-bold rounded-lg transition-all border-2 relative
                                      ${isLastWinning
                                        ? 'last-winning-number'
                                        : isWinning
                                        ? 'winning-cell'
                                        : isCalled || isFree
                                        ? 'bg-green-600 text-white border-green-700'
                                        : 'bg-white text-gray-400 border-gray-200'
                                      }
                                    `}
                                    title={isLastWinning ? `${getBingoLetter(number)}-${number} - Winning Number!` : isWinning ? `${getBingoLetter(number)}-${number}` : undefined}
                                  >
                                    {isFree ? '★' : number}
                                  </div>
                                );
                              })
                            )}
                          </div>
                        </div>
                      </div>
                    );
                  })}
                  </div>
                )}

                {/* A BUTTON, ALWAYS, ON A FINISHED GAME.
                    Until now the only way out of this modal was a timer: a
                    countdown when the game carries return_to_lobby_at, and an
                    invisible 7-second fallback when it does not. When neither
                    fired -- and for a while onReturnToLobby was withheld from
                    players entirely, so neither could -- the player was left
                    looking at "Game Over" with nothing to press.

                    Offered to everyone here, unlike the spectator button during
                    play. That one is withheld from players because leaving a
                    RUNNING round is how somebody loses a bingo they had won.
                    This game is over: there is no stake left to protect, and no
                    reason to make anyone wait out a countdown they cannot see. */}
                {onReturnToLobby && (
                  <div className="mt-6 pt-6 border-t border-gray-200 text-center">
                    <button
                      onClick={onReturnToLobby}
                      className="rounded-xl bg-blue-600 px-6 py-3 text-base font-semibold text-white shadow-lg transition-colors hover:bg-blue-700"
                    >
                      Back to lobby
                    </button>
                  </div>
                )}

                {returnCountdown !== null && returnCountdown > 0 && (
                  <div className="mt-6 pt-6 border-t border-gray-200">
                    <div className="text-center">
                      <p className="text-lg sm:text-xl text-gray-600 mb-2">
                        Returning to lobby in
                      </p>
                      <div className="inline-block bg-gradient-to-r from-blue-500 to-purple-600 text-white font-bold text-4xl sm:text-5xl px-6 py-3 rounded-xl shadow-lg">
                        {returnCountdown}
                      </div>
                      <p className="text-sm text-gray-500 mt-2">
                        All players will return together
                      </p>
                    </div>
                  </div>
                )}
              </div>
            </div>
          )}

        <div className="grid gap-2 sm:gap-3" style={{ gridTemplateColumns: '40% 60%' }}>
          <div className={`rounded-lg shadow-lg p-1 sm:p-1.5 overflow-x-auto transition-colors duration-300 ${isDarkMode ? 'bg-gray-700 border border-gray-600' : 'bg-white'}`}>
            <h3 className={`text-[9px] sm:text-[10px] lg:text-xs font-semibold mb-1 text-center ${isDarkMode ? 'text-gray-100' : 'text-gray-700'}`}>Board Size (1-75)</h3>
            <div className="grid grid-cols-5 gap-1 mb-1">
              {['B', 'I', 'N', 'G', 'O'].map((letter, index) => {
                const colors = ['bg-yellow-500', 'bg-green-600', 'bg-blue-600', 'bg-red-600', 'bg-blue-700'];
                return (
                  <div
                    key={letter}
                    className={`h-6 sm:h-7 lg:h-9 flex items-center justify-center ${colors[index]} text-white font-bold text-xs sm:text-sm lg:text-base rounded`}
                  >
                    {letter}
                  </div>
                );
              })}
            </div>
            <div className="grid grid-cols-5 gap-1">
              {boardColumns.map((column, colIndex) => (
                <div key={colIndex} className="flex flex-col gap-1">
                  {column.map((num) => {
                    const isCalled = game.called_numbers.includes(num);
                    const isCurrentNumber = game.current_number === num;
                    return (
                      <div
                        key={num}
                        className={`h-6 sm:h-7 lg:h-9 flex items-center justify-center text-[10px] sm:text-xs lg:text-sm font-bold rounded transition-all ${
                          isCurrentNumber
                            ? 'bg-yellow-400 text-gray-900 ring-1 ring-yellow-600'
                            : isCalled
                            ? 'bg-green-600 text-white'
                            : isDarkMode ? 'bg-gray-600 text-gray-200' : 'bg-gray-200 text-gray-500'
                        }`}
                      >
                        {num}
                      </div>
                    );
                  })}
                </div>
              ))}
            </div>
          </div>

          <div className="space-y-1.5 sm:space-y-2">
            {game.status === 'playing' && (
              <>
                {game.claim_window_start && (
                  <div className="bg-yellow-50 border-2 border-yellow-400 rounded-lg p-3 text-center animate-pulse">
                    <div className="flex items-center justify-center gap-2">
                      <div className="w-4 h-4 border-2 border-yellow-600 border-t-transparent rounded-full animate-spin"></div>
                      <span className="text-yellow-800 font-bold text-sm sm:text-base">Verifying winners...</span>
                    </div>
                    <p className="text-yellow-700 text-xs mt-1">Accepting simultaneous claims</p>
                  </div>
                )}
                {game.current_number && !game.claim_window_start && (
                  <div className="text-center">
                    <div className={`text-xs sm:text-sm font-bold mb-1 ${isDarkMode ? 'text-gray-200' : 'text-gray-700'}`}>Started</div>
                  </div>
                )}
                <div className={`rounded-lg p-1.5 sm:p-2 text-center transition-colors duration-300 ${isDarkMode ? 'bg-blue-700 border border-blue-600' : 'bg-blue-600'} text-white`}>
                  {game.current_number && (
                    <div className={`rounded-lg p-1.5 sm:p-2 flex items-center justify-center gap-2 sm:gap-3 ${isDarkMode ? 'bg-blue-600' : 'bg-blue-700'}`}>
                      <div className="text-xs sm:text-sm lg:text-base font-bold">Current Call</div>
                      <div className="bg-orange-500 text-white rounded-full px-2.5 sm:px-3 lg:px-4 py-1 sm:py-1.5 text-base sm:text-lg lg:text-xl font-bold">
                        {getBingoLetter(game.current_number)}-{game.current_number}
                      </div>
                    </div>
                  )}
                </div>
                {game.current_number && game.called_numbers.length > 1 && (
                  <div className="text-center pb-1">
                    <div className={`text-[10px] sm:text-xs lg:text-sm mb-1.5 font-semibold ${isDarkMode ? 'text-gray-200' : 'text-gray-600'}`}>Recent Calls</div>
                    <div className="flex justify-center gap-2 sm:gap-3 flex-wrap">
                      {game.called_numbers.slice(-3).map((num, idx) => {
                        const colors = getBingoColumnColor(num);
                        return (
                          <div
                            key={idx}
                            className={`${colors.bg} ${colors.text} rounded px-3 sm:px-4 py-2 sm:py-2.5 text-sm sm:text-base lg:text-lg font-semibold`}
                          >
                            {getBingoLetter(num)}-{num}
                          </div>
                        );
                      })}
                    </div>
                  </div>
                )}
              </>
            )}

            {isSpectator || currentPlayer?.is_disqualified ? (
              <div className={`rounded-xl shadow-lg p-6 sm:p-8 flex flex-col items-center justify-center min-h-[400px] transition-colors duration-300 ${isDarkMode ? 'bg-gray-700 border border-gray-600' : 'bg-white'}`}>
                <div className={`w-20 h-20 rounded-full flex items-center justify-center mb-4 ${isDarkMode ? 'bg-blue-600/40' : 'bg-blue-100'}`}>
                  <Eye className={`w-10 h-10 ${isDarkMode ? 'text-blue-300' : 'text-blue-600'}`} />
                </div>
                <h3 className={`text-xl sm:text-2xl font-bold mb-3 text-center ${isDarkMode ? 'text-white' : 'text-gray-900'}`}>
                  {currentPlayer?.is_disqualified ? 'Watching as Spectator' : 'Spectator Mode'}
                </h3>
                <p className={`text-sm sm:text-base text-center mb-4 ${isDarkMode ? 'text-gray-200' : 'text-gray-600'}`}>
                  {currentPlayer?.is_disqualified
                    ? 'Watch the game continue and wait for it to finish'
                    : 'Watch the action above and get ready to join the next game!'}
                </p>
                <div className={`border rounded-lg p-4 w-full max-w-sm transition-colors duration-300 ${isDarkMode ? 'bg-blue-700/30 border-blue-500' : 'bg-blue-50 border-blue-200'}`}>
                  <p className={`text-sm text-center ${isDarkMode ? 'text-blue-200' : 'text-blue-800'}`}>
                    Once this game ends, everyone returns to the lobby together for the next round
                  </p>
                </div>
              </div>
            ) : (
              <>
                <BingoCard
                  card={currentPlayer.card_numbers}
                  markedCells={localMarkedCells}
                  onCellClick={handleCellClick}
                  calledNumbers={game.called_numbers}
                  disabled={game.status !== 'playing'}
                  isDarkMode={isDarkMode}
                />
                {game.status === 'playing' && (
                  <div className="space-y-2">
                    <button
                      onClick={handleBingoClick}
                      disabled={bingoLoading || !claimable}
                      className={`w-full font-bold py-2 sm:py-2.5 lg:py-3 px-4 rounded-xl text-lg sm:text-xl lg:text-2xl transition shadow-lg touch-manipulation ${
                        bingoLoading
                          ? 'bg-orange-400 text-white opacity-75 cursor-not-allowed'
                          : !claimable
                            ? 'bg-gray-400 text-white opacity-60 cursor-not-allowed'
                            : 'bg-orange-500 hover:bg-orange-600 active:bg-orange-700 text-white'
                      } ${bingoLoading ? 'animate-pulse' : ''}`}
                    >
                      {bingoLoading ? (
                        <span className="flex items-center justify-center gap-2">
                          <span className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin"></span>
                          Claiming...
                        </span>
                      ) : (
                        'BINGO!'
                      )}
                    </button>
                    {bingoError && (
                      <div className="bg-red-50 border border-red-200 rounded-lg p-2 text-center animate-in fade-in">
                        <p className="text-red-700 text-xs sm:text-sm font-medium">{bingoError}</p>
                      </div>
                    )}
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
