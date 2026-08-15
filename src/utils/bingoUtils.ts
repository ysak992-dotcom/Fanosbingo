function seededRandom(seed: number): () => number {
  let value = seed;
  return function() {
    value = (value * 9301 + 49297) % 233280;
    return value / 233280;
  };
}

export function generateBingoCard(cardNumber?: number): number[][] {
  const random = cardNumber ? seededRandom(cardNumber) : Math.random;
  const card: number[][] = [];

  for (let col = 0; col < 5; col++) {
    const column: number[] = [];
    const min = col * 15 + 1;
    const max = col * 15 + 15;

    const availableNumbers = Array.from(
      { length: max - min + 1 },
      (_, i) => min + i
    );

    for (let row = 0; row < 5; row++) {
      if (col === 2 && row === 2) {
        column.push(0);
      } else {
        const randomValue = typeof random === 'function' ? random() : random;
        const randomIndex = Math.floor(randomValue * availableNumbers.length);
        column.push(availableNumbers[randomIndex]);
        availableNumbers.splice(randomIndex, 1);
      }
    }

    card.push(column);
  }

  return card;
}

export function checkWin(markedCells: boolean[][], card: number[][], calledNumbers: number[]): boolean {
  const isValidMark = (col: number, row: number): boolean => {
    if (col === 2 && row === 2) return true;
    return calledNumbers.includes(card[col][row]);
  };

  for (let row = 0; row < 5; row++) {
    if (markedCells.every((col, colIdx) => col[row] && isValidMark(colIdx, row))) {
      return true;
    }
  }

  for (let col = 0; col < 5; col++) {
    if (markedCells[col].every((cell, rowIdx) => cell && isValidMark(col, rowIdx))) {
      return true;
    }
  }

  let diagonal1 = true;
  let diagonal2 = true;
  for (let i = 0; i < 5; i++) {
    if (!markedCells[i][i] || !isValidMark(i, i)) diagonal1 = false;
    if (!markedCells[i][4 - i] || !isValidMark(i, 4 - i)) diagonal2 = false;
  }

  const fourCorners =
    markedCells[0][0] && isValidMark(0, 0) &&
    markedCells[4][0] && isValidMark(4, 0) &&
    markedCells[0][4] && isValidMark(0, 4) &&
    markedCells[4][4] && isValidMark(4, 4);

  return diagonal1 || diagonal2 || fourCorners;
}

export function getNextBingoNumber(calledNumbers: number[]): number | null {
  const allNumbers = Array.from({ length: 75 }, (_, i) => i + 1);
  const remainingNumbers = allNumbers.filter(num => !calledNumbers.includes(num));

  if (remainingNumbers.length === 0) return null;

  const randomIndex = Math.floor(Math.random() * remainingNumbers.length);
  return remainingNumbers[randomIndex];
}

export function getBingoLetter(number: number): string {
  if (number >= 1 && number <= 15) return 'B';
  if (number >= 16 && number <= 30) return 'I';
  if (number >= 31 && number <= 45) return 'N';
  if (number >= 46 && number <= 60) return 'G';
  if (number >= 61 && number <= 75) return 'O';
  return '';
}

export type WinningPattern = {
  type: 'row' | 'column' | 'diagonal' | 'fourCorners';
  cells: [number, number][];
  description: string;
};

export function getWinningPattern(markedCells: boolean[][], card: number[][], calledNumbers: number[]): WinningPattern | null {
  const isValidMark = (col: number, row: number): boolean => {
    if (col === 2 && row === 2) return true;
    return calledNumbers.includes(card[col][row]);
  };

  for (let row = 0; row < 5; row++) {
    if (markedCells.every((col, colIdx) => col[row] && isValidMark(colIdx, row))) {
      return {
        type: 'row',
        cells: Array.from({ length: 5 }, (_, col) => [col, row] as [number, number]),
        description: `Row ${row + 1}`
      };
    }
  }

  for (let col = 0; col < 5; col++) {
    if (markedCells[col].every((cell, rowIdx) => cell && isValidMark(col, rowIdx))) {
      const letters = ['B', 'I', 'N', 'G', 'O'];
      return {
        type: 'column',
        cells: Array.from({ length: 5 }, (_, row) => [col, row] as [number, number]),
        description: `${letters[col]} Column`
      };
    }
  }

  let diagonal1 = true;
  let diagonal2 = true;
  for (let i = 0; i < 5; i++) {
    if (!markedCells[i][i] || !isValidMark(i, i)) diagonal1 = false;
    if (!markedCells[i][4 - i] || !isValidMark(i, 4 - i)) diagonal2 = false;
  }

  if (diagonal1) {
    return {
      type: 'diagonal',
      cells: Array.from({ length: 5 }, (_, i) => [i, i] as [number, number]),
      description: 'Diagonal (Top-Left to Bottom-Right)'
    };
  }

  if (diagonal2) {
    return {
      type: 'diagonal',
      cells: Array.from({ length: 5 }, (_, i) => [i, 4 - i] as [number, number]),
      description: 'Diagonal (Top-Right to Bottom-Left)'
    };
  }

  const fourCorners =
    markedCells[0][0] && isValidMark(0, 0) &&
    markedCells[4][0] && isValidMark(4, 0) &&
    markedCells[0][4] && isValidMark(0, 4) &&
    markedCells[4][4] && isValidMark(4, 4);

  if (fourCorners) {
    return {
      type: 'fourCorners',
      cells: [[0, 0], [4, 0], [0, 4], [4, 4]],
      description: 'Four Corners'
    };
  }

  return null;
}

export function convertPatternNumbersToCells(patternNumbers: number[], card: number[][]): [number, number][] {
  const cells: [number, number][] = [];

  for (const patternNum of patternNumbers) {
    if (patternNum === 0) {
      cells.push([2, 2]);
      continue;
    }

    for (let col = 0; col < 5; col++) {
      for (let row = 0; row < 5; row++) {
        if (card[col][row] === patternNum) {
          cells.push([col, row]);
          break;
        }
      }
    }
  }

  return cells;
}

/**
 * Would the SERVER accept a claim right now?
 *
 * WHY THIS EXISTS, and it is not a convenience.
 *
 * The BINGO button is enabled whenever a game is playing, and `handleBingoClick`
 * sends the claim without checking anything. A claim the server refuses does not
 * merely fail: `atomic_claim_bingo` sets `is_disqualified = true` on the player
 * row. So one mis-tap permanently removes a player from a game they PAID A STAKE
 * to enter, with no refund -- `refund_player_stake` only fires on release, which
 * is impossible once the game has started.
 *
 * That is a live way to lose a player's money to a slip of the thumb.
 *
 * WHY IT MIRRORS THE SERVER RATHER THAN REUSING checkWin().
 *
 * checkWin() answers "does this board show a line", using markedCells. The
 * server ignores marks entirely and asks a stricter question, in
 * check_player_win():
 *
 *   1. current_number must be among called_numbers
 *   2. some pattern must contain current_number
 *   3. every number in that pattern must have been called (0 is the free centre)
 *   4. the pattern must be INCOMPLETE without current_number
 *
 * Rules 2 and 4 are what checkWin has no notion of, and they are why gating the
 * button on checkWin would not have been enough: a player holding a line
 * completed two draws ago would see an enabled button, tap it, and be
 * disqualified.
 *
 * THOSE TWO RULES ARE EQUIVALENT GIVEN RULE 3, which is worth stating so nobody
 * later "simplifies" one away believing the other is decorative. If a pattern is
 * fully called and CONTAINS the current number, then removing that number always
 * breaks it -- so rule 2 holding implies rule 4 holding, and vice versa. Removing
 * either alone leaves the guard correct; removing BOTH lets a stale line through,
 * which is what the test asserts. They are both kept because check_player_win has
 * both, and this file's job is to mirror it rather than to improve on it.
 *
 * BEING STRICTER THAN THE SERVER WOULD BE ITS OWN BUG -- a real winner unable to
 * claim loses the pot. So this is a deliberate mirror, and
 * src/utils/bingoUtils.test.ts checks it against the SAME vectors as
 * db/test/game_integrity_test.sql, so the two implementations are held to one
 * specification rather than drifting apart.
 *
 * @param cardNumbers  the card as stored, [col][row], 0 at [2][2] for the free centre
 * @param calledNumbers every number drawn so far
 * @param currentNumber the number just drawn, or null before the first draw
 */
export function canClaimBingo(
  cardNumbers: number[][] | null | undefined,
  calledNumbers: number[] | null | undefined,
  currentNumber: number | null | undefined,
): boolean {
  if (!cardNumbers || !calledNumbers || currentNumber == null) return false;
  // Rule 1. A number that was never drawn cannot complete anything.
  if (!calledNumbers.includes(currentNumber)) return false;

  const at = (col: number, row: number): number | null => {
    const v = cardNumbers[col]?.[row];
    return typeof v === 'number' ? v : null;
  };

  // The same four shapes check_player_win walks, in the same order: five rows,
  // five columns, both diagonals, then the corners.
  const patterns: (number | null)[][] = [];
  for (let row = 0; row < 5; row++) patterns.push([0, 1, 2, 3, 4].map((col) => at(col, row)));
  for (let col = 0; col < 5; col++) patterns.push([0, 1, 2, 3, 4].map((row) => at(col, row)));
  patterns.push([0, 1, 2, 3, 4].map((i) => at(i, i)));
  patterns.push([0, 1, 2, 3, 4].map((i) => at(i, 4 - i)));
  patterns.push([at(0, 0), at(4, 0), at(0, 4), at(4, 4)]);

  return patterns.some((cells) => {
    if (cells.some((c) => c === null)) return false;
    const nums = cells as number[];

    // Rule 2.
    if (!nums.includes(currentNumber)) return false;

    // Rule 3. 0 is the free centre and is never called.
    const complete = nums.every((n) => n === 0 || calledNumbers.includes(n));
    if (!complete) return false;

    // Rule 4. Without the current number the pattern must NOT stand -- the claim
    // belongs to the draw that completed it, not to any later draw.
    const without = calledNumbers.filter((n) => n !== currentNumber);
    return !nums.every((n) => n === 0 || without.includes(n));
  });
}
