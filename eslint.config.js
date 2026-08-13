import js from '@eslint/js';
import globals from 'globals';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    // `dist` is build output. `supabase/functions` is INHERITED SOURCE that has
    // never run in this deployment -- AGENTS.md is explicit that the 25 Deno
    // edge functions belong to the hosted Supabase project this fork never had,
    // and the ones that matter were ported to services/functions, which IS
    // linted and tested.
    //
    // Excluded rather than fixed, because fixing it would mean maintaining code
    // that executes nowhere -- and gating on it would mean a red pipeline owned
    // by nobody. If a function is ever ported, it moves to services/ and picks
    // up the checks that apply there.
    ignores: ['dist', 'supabase/functions/**'],
  },
  {
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
    },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],

      // Make the underscore convention the codebase already uses actually work.
      //
      // `_cardLayout` in src/App.tsx is deliberately accepted and ignored -- the
      // server derives the card layout, and the parameter stays only because
      // Lobby still passes it. tsc honours the leading underscore; eslint did
      // not, so the file has been carrying an error for a convention it was
      // following correctly. `_user` joined it for the same reason.
      //
      // Applied to arguments and to caught errors, not to variables: an unused
      // local is usually a mistake, where an unused parameter in the middle of a
      // signature cannot be removed without changing every caller.
      // WARN, NOT ERROR, AND THIS IS A SCOPING DECISION RATHER THAN A PASS.
      //
      // 23 of these exist and they are concentrated in three files of generic
      // plumbing: supabase realtime payload callbacks, a promise queue, and
      // `(navigator as any).connection` -- the Network Information API, which
      // TypeScript's lib types do not describe, so the cast is the documented
      // workaround rather than laziness.
      //
      // Converting them to `unknown` is the right end state and forces
      // narrowing at every call site. Doing that blind, in code with no tests
      // around it, to make a new gate go green, would be changing working
      // plumbing for the sake of the gate -- which is how a gate ends up
      // trusted less than the code it checks.
      //
      // A warning still prints on every run, so new ones are visible. Gating on
      // errors gets the check running today against the mistakes it actually
      // catches -- an unused variable, an empty pattern, a bad hook dependency.
      // Raise this to 'error' when the three files are typed.
      '@typescript-eslint/no-explicit-any': 'warn',

      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
        },
      ],
    },
  }
);
