/**
 * Tests for bingoUtils.ts.
 *
 * WHY THIS FILE AND NOT A COMPONENT TEST. Lobby.tsx, GameRoom.tsx and Admin.tsx
 * are 3,266 lines between them and had no coverage at all, but rendering them
 * needs a DOM, a Supabase client, a Telegram SDK and a router -- and what would
 * be asserted is mostly that React rendered. The DECISIONS those components make
 * about money live in here, in functions that take arrays and return answers.
 * This is where a test earns its keep.
 *
 * checkWin() is the one that matters. It decides whether the client offers a
 * player the claim button, and a claim is a route that pays out. The server
 * re-decides it in atomic_claim_bingo -- the browser is not trusted -- so a bug
 * here does not directly pay anybody. What it does is either offer a claim the
 * server then refuses, which reads to a player as the game cheating them, or
 * fail to offer one they had actually won, which is worse and silent.
 *
 * THE ASSERTION THAT MATTERS MOST is the "marked but never called" case. Marks
 * are client state; calls are server state. A checkWin that trusted marks alone
 * would light up the claim button for anybody who tapped five cells.
 *
 * Run: npx tsx src/utils/bingoUtils.test.ts
 */

import {
  generateBingoCard,
  checkWin,
  canClaimBingo,
  getBingoLetter,
  getWinningPattern,
  convertPatternNumbersToCells,
} from './bingoUtils';
import { formatBirr, formatBirrWithUnit, CURRENCY_LABEL } from './formatBalance';

let failures = 0;
const check = (label: string, cond: boolean) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

/** All cells unmarked. Indexed [col][row], as the component stores them. */
const noMarks = (): boolean[][] =>
  Array.from({ length: 5 }, () => Array.from({ length: 5 }, () => false));

/** The free centre square, which starts marked. Mirrors buildMarkedCells(). */
const withFreeCentre = (): boolean[][] => {
  const m = noMarks();
  m[2][2] = true;
  return m;
};

/** Every number on the card, so nothing fails for want of having been called. */
const allNumbers = (card: number[][]): number[] => card.flat().filter((n) => n !== 0);

console.log('\ngenerateBingoCard');

{
  const card = generateBingoCard(42);

  check('five columns of five', card.length === 5 && card.every((c) => c.length === 5));

  // B 1-15, I 16-30, N 31-45, G 46-60, O 61-75. A number in the wrong column
  // makes getBingoLetter disagree with where the cell is drawn.
  const inRange = card.every((column, col) =>
    column.every((n, row) => (col === 2 && row === 2) || (n >= col * 15 + 1 && n <= col * 15 + 15)),
  );
  check('every number is inside its column range', inRange);

  check('the centre is the free square', card[2][2] === 0);

  const noDupes = card.every((column) => {
    const real = column.filter((n) => n !== 0);
    return new Set(real).size === real.length;
  });
  check('no column repeats a number', noDupes);

  // DETERMINISM. services/functions/src/select-card.js takes the layout from
  // get_or_create_card_layout() precisely so the player cannot choose it, and
  // states that the same card number always yields the same board. The client
  // generator must agree, or the board a player picks from differs from the one
  // they are dealt.
  check(
    'the same card number yields the same card',
    JSON.stringify(generateBingoCard(42)) === JSON.stringify(card),
  );
  check(
    'a different card number yields a different card',
    JSON.stringify(generateBingoCard(43)) !== JSON.stringify(card),
  );
}

console.log('\ncheckWin — the shapes that win');

{
  const card = generateBingoCard(7);
  const called = allNumbers(card);

  for (let row = 0; row < 5; row++) {
    const marks = withFreeCentre();
    for (let col = 0; col < 5; col++) marks[col][row] = true;
    check(`row ${row + 1} wins`, checkWin(marks, card, called) === true);
  }

  for (let col = 0; col < 5; col++) {
    const marks = withFreeCentre();
    for (let row = 0; row < 5; row++) marks[col][row] = true;
    check(`column ${col + 1} wins`, checkWin(marks, card, called) === true);
  }

  {
    const marks = withFreeCentre();
    for (let i = 0; i < 5; i++) marks[i][i] = true;
    check('the top-left diagonal wins', checkWin(marks, card, called) === true);
  }

  {
    const marks = withFreeCentre();
    for (let i = 0; i < 5; i++) marks[i][4 - i] = true;
    check('the top-right diagonal wins', checkWin(marks, card, called) === true);
  }

  {
    const marks = withFreeCentre();
    marks[0][0] = marks[4][0] = marks[0][4] = marks[4][4] = true;
    check('four corners wins', checkWin(marks, card, called) === true);
  }
}

console.log('\ncheckWin — the shapes that must NOT win');

{
  const card = generateBingoCard(7);
  const called = allNumbers(card);

  check('an empty card does not win', checkWin(withFreeCentre(), card, called) === false);

  {
    const marks = withFreeCentre();
    for (let col = 0; col < 4; col++) marks[col][0] = true;
    check('four of a row does not win', checkWin(marks, card, called) === false);
  }

  {
    // Marked cells that form no line at all.
    const marks = withFreeCentre();
    marks[0][0] = true;
    marks[1][2] = true;
    marks[3][1] = true;
    marks[4][3] = true;
    check('scattered marks do not win', checkWin(marks, card, called) === false);
  }

  // THE ONE THAT MATTERS. A full row marked, and NOTHING has been called.
  {
    const marks = withFreeCentre();
    for (let col = 0; col < 5; col++) marks[col][0] = true;
    check(
      'a full row marked with NO numbers called does not win',
      checkWin(marks, card, []) === false,
    );
  }

  // And the near-miss: every number in the row called except one.
  {
    const marks = withFreeCentre();
    for (let col = 0; col < 5; col++) marks[col][0] = true;
    const missingOne = allNumbers(card).filter((n) => n !== card[3][0]);
    check(
      'one uncalled number in the row is enough to refuse the win',
      checkWin(marks, card, missingOne) === false,
    );
  }

  // The free centre must be free WITHOUT having been called -- 0 is not a real
  // bingo number and will never appear in calledNumbers.
  {
    const marks = withFreeCentre();
    for (let row = 0; row < 5; row++) marks[2][row] = true;
    const calledWithoutZero = allNumbers(card);
    check(
      'the middle column wins through the free centre, which is never called',
      checkWin(marks, card, calledWithoutZero) === true,
    );
  }
}

console.log('\ngetWinningPattern agrees with checkWin');

{
  const card = generateBingoCard(11);
  const called = allNumbers(card);

  const marks = withFreeCentre();
  for (let col = 0; col < 5; col++) marks[col][2] = true;

  const pattern = getWinningPattern(marks, card, called);
  check('a winning board reports a pattern', pattern !== null);
  check('and identifies it as a row', pattern?.type === 'row');
  check('with five cells', pattern?.cells.length === 5);

  check(
    'a losing board reports no pattern',
    getWinningPattern(withFreeCentre(), card, called) === null,
  );

  // The two functions are separate implementations of the same rule, which is
  // exactly the kind of pair that drifts. Asserted across many boards rather
  // than one, because a disagreement on an unusual layout is the likely form.
  let disagreements = 0;
  for (let n = 1; n <= 60; n++) {
    const c = generateBingoCard(n);
    const all = allNumbers(c);
    const m = withFreeCentre();
    for (let i = 0; i < 5; i++) m[i][i] = true;
    if (checkWin(m, c, all) !== (getWinningPattern(m, c, all) !== null)) disagreements++;
  }
  check('checkWin and getWinningPattern agree across 60 cards', disagreements === 0);
}

console.log('\nconvertPatternNumbersToCells');

{
  const card = generateBingoCard(3);
  const cells = convertPatternNumbersToCells([card[0][0], card[1][1]], card);
  check('resolves numbers back to their coordinates', cells.length === 2);
  check('and the coordinates point at those numbers', card[cells[0][0]][cells[0][1]] === card[0][0]);
}

console.log('\ngetBingoLetter — the boundaries, which is where an off-by-one lives');

{
  const cases: [number, string][] = [
    [1, 'B'], [15, 'B'],
    [16, 'I'], [30, 'I'],
    [31, 'N'], [45, 'N'],
    [46, 'G'], [60, 'G'],
    [61, 'O'], [75, 'O'],
  ];
  const wrong = cases.filter(([n, want]) => getBingoLetter(n) !== want);
  check('every column boundary maps to the right letter', wrong.length === 0);
  check('0 and 76 map to nothing rather than to B or O', getBingoLetter(0) === '' && getBingoLetter(76) === '');
}

console.log('\nformatBirr — this renders money to a player');

{
  check('whole birr are grouped', formatBirr(1234567) === '1,234,567');
  check('zero is 0', formatBirr(0) === '0');

  // The column is an integer and the file says so. What matters is that a
  // fractional value is not silently DROPPED to something smaller -- a balance
  // shown as less than it is generates a support message.
  check('40.6 rounds to 41, not 40', formatBirr(40.6) === '41');
  check('40.4 rounds to 40', formatBirr(40.4) === '40');

  // NaN and Infinity reach this from an arithmetic slip upstream. Rendering
  // "NaN" where a balance goes is worse than rendering 0, because a player reads
  // it as their money having vanished.
  check('NaN renders as 0', formatBirr(NaN) === '0');
  check('Infinity renders as 0', formatBirr(Infinity) === '0');

  check('the unit form appends the Amharic label', formatBirrWithUnit(40) === `40 ${CURRENCY_LABEL}`);
}

console.log('\ncanClaimBingo — the guard on a button that can disqualify you');

{
  // THE SAME CARD AND THE SAME VECTORS as db/test/game_integrity_test.sql, so
  // the TypeScript mirror and the SQL original are held to one specification.
  // If they ever disagree, one of these suites fails and says so.
  //
  // Row 0 is [1, 16, 31, 46, 61]; the free centre is at [2][2], in row 2.
  const card = [
    [1, 2, 3, 4, 5],
    [16, 17, 18, 19, 20],
    [31, 32, 0, 34, 35],
    [46, 47, 48, 49, 50],
    [61, 62, 63, 64, 65],
  ];

  // integrity test 2: a genuine completed line, claimed on the number that
  // completed it.
  check('a line completed by the current number CAN be claimed',
    canClaimBingo(card, [1, 16, 31, 46, 61], 61) === true);

  // integrity test 3: the line was completed two draws ago. The server refuses
  // this and disqualifies; the button must therefore be dead.
  check('a line completed by an EARLIER draw cannot be claimed',
    canClaimBingo(card, [1, 16, 31, 46, 61, 2], 2) === false);

  // integrity test 4: the current number was never drawn.
  check('an undrawn current number cannot be claimed',
    canClaimBingo(card, [1, 16, 31, 46], 61) === false);

  // integrity test 1: one number called, no line anywhere.
  check('an incomplete card cannot be claimed', canClaimBingo(card, [1], 1) === false);

  // The free centre counts without ever being called: column 2 is
  // [31, 32, 0, 34, 35].
  check('the free centre completes a column without being drawn',
    canClaimBingo(card, [31, 32, 34, 35], 35) === true);

  // Both diagonals. [0,0][1,1][2,2][3,3][4,4] = 1,17,0,49,65
  check('the top-left diagonal counts',
    canClaimBingo(card, [1, 17, 49, 65], 65) === true);
  // [0,4][1,3][2,2][3,1][4,0] = 5,19,0,47,61
  check('the top-right diagonal counts',
    canClaimBingo(card, [5, 19, 47, 61], 61) === true);

  // Four corners: [0,0]=1 [4,0]=61 [0,4]=5 [4,4]=65
  check('four corners counts', canClaimBingo(card, [1, 61, 5, 65], 65) === true);

  // Degenerate inputs reach this from a game that has not drawn yet. The button
  // must be dead rather than throwing.
  check('no current number -> cannot claim', canClaimBingo(card, [1, 2], null) === false);
  check('no called numbers -> cannot claim', canClaimBingo(card, [], 1) === false);
  check('no card -> cannot claim', canClaimBingo(null, [1], 1) === false);
}

console.log(failures === 0 ? '\nAll Mini App logic tests passed.' : `\n${failures} FAILED.`);
process.exit(failures === 0 ? 0 : 1);
