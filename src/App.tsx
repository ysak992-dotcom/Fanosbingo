import { useState, useEffect, useCallback, useRef, lazy, Suspense } from 'react';
import { Lobby } from './components/Lobby';
import { GameRoom } from './components/GameRoom';
import { BankDepositModal } from './components/BankDepositModal';
import { NetworkQualityIndicator } from './components/NetworkQualityIndicator';
import { supabase } from './lib/supabase';
import { initTelegram, getStartParam, TelegramUser } from './utils/telegram';
import { authenticate, getAccessToken } from './lib/auth';
import { CRYPTO_ENABLED } from './lib/features';

const Admin = lazy(() => import('./components/Admin').then(module => ({ default: module.Admin })));

// The wallet stack, behind a dynamic import. With CRYPTO_ENABLED false this
// lazy() is never invoked, so the chunk is never fetched -- which is the whole
// point, and the reason the PROVIDER moved rather than just the modals. See
// src/components/CryptoProvider.tsx.
const CryptoProvider = lazy(() => import('./components/CryptoProvider'));

type View = 'lobby' | 'game' | 'admin';

interface AppContentProps {
  /**
   * A player resolved from a connected wallet, or null.
   *
   * Always null when crypto is disabled. Passed down rather than read from a
   * context so this component compiles and runs with the wallet stack absent
   * entirely.
   */
  walletUser: TelegramUser | null;
}

function AppContent({ walletUser }: AppContentProps) {
  const [view, setView] = useState<View>('lobby');
  const [appUser, setAppUser] = useState<TelegramUser | null>(null);
  // The game the user deliberately walked away from, if any.
  //
  // A REF, not state, on purpose: the auto-enter effect below depends on
  // [appUser, gameId, gameStarted], and adding another state value to that list
  // would tear down and rebuild its realtime subscription and its 10s interval
  // every time somebody left a game. A ref is read by the existing closure
  // without changing when it re-subscribes.
  // "The user chose to leave a round they were only watching."
  //
  // A BOOLEAN, not a game id. It held the id so the dismissal could be scoped to
  // one round -- which meant leaving worked until the next round started and
  // then silently stopped, and rounds run continuously. It also had to be READ
  // OUT of the gameId state to be set, so a null there would have left the
  // guard inert with nothing to show for it.
  //
  // Cleared whenever entry is deliberate -- joining, or tapping Watch -- so
  // this only ever suppresses the automatic entry it was written for.
  const leftVoluntarilyRef = useRef(false);

  // Whether the viewer holds a card in the game currently on screen.
  //
  // SEPARATE FROM playerId BEING NULL, which conflates "is not a player" with
  // "their row has not loaded yet". GameRoom derives isSpectator from
  // `!playerId`, so during that gap a real player renders as a spectator -- which
  // is what put the Back button in front of somebody who could not use it.
  //
  // The poll already answers this properly, by looking for a players row. Keep
  // the answer rather than re-deriving it from a value that means two things.
  const [holdsCardInGame, setHoldsCardInGame] = useState(false);

  const [gameId, setGameId] = useState<string | null>(() => localStorage.getItem('gameId'));
  const [playerId, setPlayerId] = useState<string | null>(() => localStorage.getItem('playerId'));
  const [gameStarted, setGameStarted] = useState(false);
  const [showDepositModal, setShowDepositModal] = useState(false);

  useEffect(() => {
    // Exchange Telegram's SIGNED initData for a session token before doing
    // anything else.
    //
    // The identity used to come from initDataUnsafe -- Telegram's own word for
    // "parsed but not verified" -- and was then sent to the API as a plain
    // telegram id the server had no way to check. Now the API verifies the HMAC
    // and returns a token whose claims RLS enforces on every query.
    //
    // The returned user is preferred over the local one because it is the one
    // the server PROVED. Falling back to initTelegram() keeps the app usable
    // outside Telegram -- a browser tab, a preview -- where there is no
    // signature to verify and RLS correctly shows only anonymous data.
    const bootstrapIdentity = async () => {
      const verified = await authenticate();

      if (verified) {
        setAppUser({
          id: Number(verified.telegram_user_id),
          first_name: verified.first_name,
          username: verified.username,
        });
        return;
      }

      const telegramData = initTelegram();
      if (telegramData.user) {
        setAppUser(telegramData.user);
      }
    };

    void bootstrapIdentity();
  }, []);

  // The wallet-login path, now that its useAccount() lives in CryptoProvider.
  //
  // Telegram wins if it got there first: `!appUser` means a Mini App player who
  // also has a wallet connected is not re-identified as the wallet account.
  // That was the previous behaviour too -- the old effect began `if (appUser ...)
  // return` -- it is just expressed here instead.
  useEffect(() => {
    if (walletUser && !appUser) setAppUser(walletUser);
  }, [walletUser, appUser]);

  useEffect(() => {
    if (gameId) {
      localStorage.setItem('gameId', gameId);
    } else {
      localStorage.removeItem('gameId');
    }
  }, [gameId]);

  useEffect(() => {
    if (playerId) {
      localStorage.setItem('playerId', playerId);
    } else {
      localStorage.removeItem('playerId');
    }
  }, [playerId]);

  useEffect(() => {
    const restoreSession = async () => {
      if (!playerId || !gameId) return;

      const { data: game } = await supabase
        .from('games')
        .select('status')
        .eq('id', gameId)
        .maybeSingle();

      if (game?.status === 'playing' || game?.status === 'finished') {
        setGameStarted(true);
      } else if (!game) {
        setGameId(null);
        setPlayerId(null);
        setGameStarted(false);
      }
    };

    restoreSession();
  }, []);

  useEffect(() => {
    const checkForActiveGames = async () => {
      if (gameId && gameStarted) {
        const { data: currentGame } = await supabase
          .from('games')
          .select('status')
          .eq('id', gameId)
          .maybeSingle();

        if (currentGame?.status === 'finished' || currentGame?.status === 'playing') {
          return;
        }
      }

      // THE GAME THIS PLAYER IS IN, BEFORE THE NEWEST ONE THAT EXISTS.
      //
      // This used to be only the query below -- newest `playing` game, no
      // reference to the user at all -- and that is what made "Back to lobby"
      // look broken through three separate attempts to fix it.
      //
      // Rounds run continuously, so a player sitting in game A is pulled into
      // game B the moment B starts. The `players` lookup underneath is scoped to
      // whichever game this picked, so it finds no row, sets playerId to null,
      // and GameRoom renders `isSpectator` from `!playerId`. The player is shown
      // the Spectator panel for a round they are not in, having been taken out
      // of the one they paid for.
      //
      // It also explains why the button looked DEAD rather than flaky: the
      // dismissal below is scoped to one game id, so leaving worked until the
      // next round started and then stopped. The dismissal logic was correct
      // throughout -- which is why three fixes aimed at it changed nothing.
      //
      // So ask the question that matters first: is this user in a running game?
      // Only if they are not does "the newest running game" mean anything, and
      // for them entry is a choice (the Watch button) rather than something a
      // poll does to them.
      let ownGameId: string | null = null;
      if (appUser) {
        const { data: ownRows } = await supabase
          .from('players')
          .select('game_id, games!inner(status)')
          .eq('telegram_user_id', appUser.id)
          .eq('games.status', 'playing')
          .limit(1);
        ownGameId = ownRows?.[0]?.game_id ?? null;
      }

      const { data: playingGames } = await supabase
        .from('games')
        .select('id')
        .eq('status', 'playing')
        .order('created_at', { ascending: false })
        .limit(1);

      if (ownGameId || (playingGames && playingGames.length > 0)) {
        const activeGameId = ownGameId ?? playingGames![0].id;

        // Hoisted out of the `if` so the spectator check below can read it.
        // Declaring it inside was a ReferenceError at runtime, caught by
        // `npm run typecheck` and NOT by the build -- vite does not typecheck,
        // so this would have shipped as a white screen the moment a round
        // started. The advisory typecheck job earned its place here.
        let isPlayerInThisGame = false;

        if (appUser) {
          const { data: playerRecord } = await supabase
            .from('players')
            .select('id')
            .eq('game_id', activeGameId)
            .eq('telegram_user_id', appUser.id)
            .maybeSingle();

          isPlayerInThisGame = Boolean(playerRecord?.id);
          setPlayerId(playerRecord?.id || null);
          setHoldsCardInGame(isPlayerInThisGame);
        } else {
          setPlayerId(null);
          setHoldsCardInGame(false);
        }

        // DO NOT DRAG A SPECTATOR BACK IN.
        //
        // This effect force-enters the running game on every poll, which is
        // right for a PLAYER -- they have paid for a card and should be in the
        // round they bought, whatever else they tap.
        //
        // It is wrong for a spectator, and it is what made "Back to lobby" look
        // broken: the handler cleared gameId and gameStarted, and within ten
        // seconds this put them straight back. From the outside the button did
        // nothing.
        //
        // So a deliberate exit is honoured only for somebody with NO player row
        // in that game.
        //
        // NO LONGER SCOPED TO ONE GAME ID. It was, on the reasoning that "the
        // next round enters normally rather than leaving them stranded in the
        // lobby" -- but rounds run continuously, so the next round is never more
        // than a moment away. The practical effect was that leaving worked until
        // a new game started and then silently stopped, which is the difference
        // between a button that is flaky and one that looks dead.
        //
        // Somebody with no card is not stranded by staying in the lobby: the
        // lobby is where you join, and Lobby.tsx offers Watch for a round in
        // progress. Being returned to it is what they asked for.
        //
        // Entering is still automatic for a PLAYER, which is the case this
        // effect exists for -- they paid for a card and should be in the round
        // they bought whatever else they tap.
        if (!isPlayerInThisGame && leftVoluntarilyRef.current) {
          setGameStarted(false);
          return;
        }

        setGameId(activeGameId);
        setGameStarted(true);
      } else {
        if (gameId) {
          const { data: currentGame } = await supabase
            .from('games')
            .select('status')
            .eq('id', gameId)
            .maybeSingle();

          if (currentGame?.status === 'finished') {
            setGameStarted(true);
          } else {
            setGameStarted(false);
          }
        } else {
          setGameStarted(false);
        }
      }
    };

    checkForActiveGames();

    const activeGameChannel = supabase
      .channel('auto-redirect-games')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'games' },
        () => { checkForActiveGames(); }
      )
      .subscribe();

    const pollInterval = setInterval(() => {
      if (!document.hidden) {
        checkForActiveGames();
      }
    }, 10000);

    return () => {
      supabase.removeChannel(activeGameChannel);
      clearInterval(pollInterval);
    };
  }, [appUser, gameId, gameStarted]);

  useEffect(() => {
    if (!playerId || !gameId) return;

    const playerChannel = supabase
      .channel(`player:${playerId}`)
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'games', filter: `id=eq.${gameId}` },
        (payload) => {
          const updatedGame = payload.new as { status: string };
          if (updatedGame.status === 'playing') {
            setGameStarted(true);
          }
        }
      )
      .subscribe();

    const pollInterval = setInterval(async () => {
      if (document.hidden) return;

      const { data: game } = await supabase
        .from('games')
        .select('status')
        .eq('id', gameId)
        .maybeSingle();

      if (game?.status === 'playing' && !gameStarted) {
        setGameStarted(true);
      }
    }, 5000);

    return () => {
      supabase.removeChannel(playerChannel);
      clearInterval(pollInterval);
    };
  }, [playerId, gameId, gameStarted]);

  // `user` and the former `cardLayout` parameter are gone from the request body:
  // the server derives both from the verified token and from the card number. The
  // parameter is kept in the signature because Lobby still passes it, and removing
  // it is a caller change belonging with the next route rather than this one.
  // `_user` joins `_cardLayout` in being accepted and ignored. It was last read
  // by the balance lookup removed below; the server derives identity from the
  // token. Kept in the signature because Lobby still passes it -- dropping both
  // is a caller change that belongs with the next route, not with this one.
  const handleJoinGame = async (gameId: string, selectedNumber: number, _user: TelegramUser, _cardLayout?: number[][]) => {

    const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;

    // The PLAYER'S token, not the anon key.
    //
    // This route requires a proven identity and derives everything else from it,
    // so sending the anon key would simply be rejected. Previously the anon key
    // was sent and the identity came from the body below, which the server had no
    // way to check.
    const token = await getAccessToken();

    // gameId and cardNumber ONLY. Everything else this used to send is now
    // derived server-side, and deliberately so:
    //
    //   telegramUserId    was the caller naming their own account. The server
    //                     takes it from the verified token instead.
    //   playerName etc.   read from the row the server stores for that identity.
    //   cardLayout        THE PLAYER CHOOSING THEIR OWN BINGO CARD. It went
    //                     straight into players.card_numbers, so a crafted
    //                     request could join with a card of numbers already
    //                     called. Now from get_or_create_card_layout(cardNumber),
    //                     which is deterministic and identical for everybody.
    //
    // Choosing a card NUMBER is still the player's decision. Choosing what is
    // printed on it never was.
    const response = await fetch(`${supabaseUrl}/functions/v1/select-card`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        gameId,
        cardNumber: selectedNumber,
      }),
    });

    const result = await response.json();

    if (!response.ok) {
      if (result.error === 'Insufficient balance') {
        // Just open the deposit modal.
        //
        // This used to fetch deposited_balance and won_balance first and store
        // the sum in a `userBalance` state that NOTHING read -- tsc reported it
        // as TS6133. So the round trip happened on every failed join, on the
        // error path, to populate a variable that was never rendered. Dropped
        // along with the state.
        setShowDepositModal(true);
      }
      throw new Error(result.error || 'Failed to join game');
    }

    // Joining clears any prior "I left this round": they are a player now, and
    // the effect should keep them in the game they have paid for.
    leftVoluntarilyRef.current = false;
    setPlayerId(result.playerId);
    setGameId(gameId);
  };

  const handleSpectateGame = (gameId: string) => {
    // Asking to watch it again undoes a previous "leave".
    leftVoluntarilyRef.current = false;
    setGameId(gameId);
    setGameStarted(true);
    setView('game');
  };

  // THE ADMIN PANEL WAS UNREACHABLE, which is not the same as unbuilt.
  //
  // The only way in was `window.location.pathname === '/admin'`. A Telegram Mini
  // App opens at the URL BotFather is configured with and has no address bar, so
  // that path could only be typed in a desktop browser -- where there is no
  // initData, therefore no token, therefore a 401 from every admin route. The
  // deposit queue, the withdrawal queue, settings and end-game were all deployed
  // and none of them could be opened by the person who needs them.
  //
  // `startapp` is Telegram's own mechanism for this:
  //
  //     https://t.me/BingoNovaaBot/app?startapp=admin
  //
  // which opens the Mini App normally -- real initData, real token -- and hands
  // the value through. See getStartParam() for why reading it from the UNSAFE
  // payload is acceptable: it chooses a view, and the server still decides
  // whether that view has anything in it.
  //
  // The pathname check stays for local development against a dev server.
  useEffect(() => {
    const checkAdminPath = () => {
      if (window.location.pathname === '/admin' || getStartParam() === 'admin') {
        setView('admin');
      }
    };
    checkAdminPath();
    window.addEventListener('popstate', checkAdminPath);
    return () => window.removeEventListener('popstate', checkAdminPath);
  }, []);

  const handleReturnToLobby = useCallback(() => {
    // Record that leaving was deliberate, so the auto-enter effect can tell it
    // from "the user has not seen this round yet". Without it, clearing the
    // state below is undone by the next poll.
    leftVoluntarilyRef.current = true;
    setGameId(null);

    localStorage.removeItem('gameId');
    localStorage.removeItem('playerId');
    setPlayerId(null);
    setGameStarted(false);
  }, []);

  if (view === 'admin') {
    return (
      <>
        <Suspense fallback={<div className="min-h-screen bg-gradient-to-br from-blue-50 to-indigo-100 flex items-center justify-center"><div className="text-gray-600">Loading admin panel...</div></div>}>
          <Admin />
        </Suspense>
        <NetworkQualityIndicator />
      </>
    );
  }

  if (gameId && gameStarted) {
    return (
      <>
        {/*
          NO MANUAL EXIT FOR A PLAYER, but the callback is ALWAYS passed.

          Passing `undefined` here to hide the button also removed the automatic
          return that fires when a game FINISHES -- the same prop backs both --
          so a player who reached "Game Over" was stranded with no way out.
          That regression shipped in #132 and was found in dev the next day.
          canExitEarly hides the button and leaves the automatic path alone.

          This effect re-enters a player on every poll -- deliberately: they paid
          for a card, the claim is manual, and leaving the round is how somebody
          loses a bingo they had won. So the button could never work for them,
          and offering it was a promise the code refuses to keep. Tapping it
          cleared the state, the next poll put it straight back, and the only
          visible effect was the button itself disappearing.

          A genuine spectator has nothing at stake and nothing to miss, so for
          them it works and stays.

          Withheld here rather than hidden inside GameRoom, because this is where
          the answer is actually known. GameRoom only has playerId, which is null
          both for a spectator and for a player whose row has not loaded.
        */}
        <GameRoom
          gameId={gameId}
          playerId={playerId}
          onReturnToLobby={handleReturnToLobby}
          canExitEarly={!holdsCardInGame}
        />
        {appUser && (
          <BankDepositModal
            isOpen={showDepositModal}
            onClose={() => setShowDepositModal(false)}
            telegramUserId={appUser.id}
          />
        )}
        <NetworkQualityIndicator />
      </>
    );
  }

  return (
    <>
      <Lobby onJoinGame={handleJoinGame} onSpectateGame={handleSpectateGame} telegramUser={appUser} />
      {appUser && (
        <BankDepositModal
          isOpen={showDepositModal}
          onClose={() => setShowDepositModal(false)}
          telegramUserId={appUser.id}
        />
      )}
      <NetworkQualityIndicator />
    </>
  );
}

/**
 * The gate.
 *
 * With CRYPTO_ENABLED false this returns AppContent directly, the lazy() above
 * is never invoked, and the wallet chunk is never requested -- so the saving is
 * real rather than deferred to a second render.
 *
 * With it true the tree is identical to what App used to render, plus the
 * identity bridge that moved out of AppContent.
 *
 * `fallback={null}` rather than a spinner: this resolves from cache in
 * milliseconds and a flash of loading UI ahead of the lobby is worse than a
 * frame of nothing. Rendering AppContent as the fallback would be wrong for a
 * different reason -- it would mount, then remount inside the provider, running
 * every bootstrap effect twice.
 */
function App() {
  const [walletUser, setWalletUser] = useState<TelegramUser | null>(null);

  if (!CRYPTO_ENABLED) {
    return <AppContent walletUser={null} />;
  }

  return (
    <Suspense fallback={null}>
      <CryptoProvider onWalletUser={setWalletUser} needsIdentity={walletUser === null}>
        <AppContent walletUser={walletUser} />
      </CryptoProvider>
    </Suspense>
  );
}

export default App;
