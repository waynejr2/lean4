/-
Copyright (c) 2018 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Leonardo de Moura

Implementation for the parsec parser combinators described in the
paper:
https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/parsec-paper-letter.pdf
-/
prelude
import init.data.to_string init.data.string.basic init.data.list.basic init.control.except
import init.data.repr
namespace lean.parser
@[reducible] def position : Type := nat

structure message :=
(pos        : position    := 0)
(unexpected : string      := "")      -- unexpected input
(expected   : list string := []) -- expected productions

open string (iterator)

def expected.to_string : list string → string
| []       := ""
| [e]      := e
| [e1, e2] := e1 ++ " or " ++ e2
| (e::es)  := e ++ ", " ++ expected.to_string es

protected def message.to_string (input : string) (msg : message) : string :=
let (line, col) := input.line_column msg.pos in
"error at (line : " ++ to_string line ++ ", column: " ++ to_string col ++ ")\n" ++
"unexpected " ++ msg.unexpected ++ "\n" ++
if msg.expected = [] then "" else "expected " ++ expected.to_string msg.expected

def message.repr (msg : message) : string :=
"{pos := " ++ repr msg.pos ++ ", " ++
 "unexpected := " ++ repr msg.unexpected ++ ", " ++
 "expected := " ++ repr msg.expected ++ "}"

instance message_has_repr : has_repr message :=
⟨message.repr⟩

/-
Remark: we store error messages in `ok_eps` results.
They contain the error that would have occurred if a
successful "epsilon" alternative was not taken.
-/
inductive result (α : Type)
| ok (a : α) (it : iterator)                     : result
| ok_eps (a : α) (it : iterator) (msg : message) : result
| error {} (msg : message) (consumed : bool)     : result

open result

def parser (α : Type) :=
iterator → result α

variables {α β : Type}

def run (p : parser α) (s : string) (fname := "") : except message α :=
match p s.mk_iterator with
| ok a _       := except.ok a
| ok_eps a _ _ := except.ok a
| error msg _  := except.error msg
end

@[inline] def mk_eps_result (a : α) (it : iterator) : result α :=
ok_eps a it { pos := it.offset }

protected def pure (a : α) : parser α :=
λ it, mk_eps_result a it

def eps : parser unit :=
parser.pure ()

protected def failure : parser α :=
λ it, error { unexpected := "failure", pos := it.offset } ff

def merge (msg₁ msg₂ : message) : message :=
{ expected := msg₁.expected ++ msg₂.expected, ..msg₁ }

def merge' (msg₁ msg₂ : message) : message :=
{ expected := msg₁.expected ++ msg₂.expected, ..msg₂ }

def merge_error (msg₁ msg₂ : message) : result α :=
error (merge msg₁ msg₂) ff

def merge_error' (msg₁ msg₂ : message) : result α :=
error (merge' msg₁ msg₂) ff

def merge_ok_epsilon (a : α) (it : iterator) (msg₁ msg₂ : message) :=
ok_eps a it (merge msg₁ msg₂)

/--
  The `bind p q` combinator behaves as follows:
  1- If `p` fails, then it fails.
  2- If `p` succeeds and consumes input, then execute `q`
  3- If `q` succeeds but does not consume input, then execute `q`
     and merge error messages if both do not consume any input.
-/
protected def bind (p : parser α) (q : α → parser β) : parser β :=
λ it, match p it with
     | ok a it :=
       match q a it with
       | ok_eps b it msg₂ := ok b it
       | error msg ff     := error msg tt
       | other            := other
       end
     | ok_eps a it msg₁ :=
       match q a it with
       | ok_eps b it msg₂ := merge_ok_epsilon b it msg₁ msg₂
       | error msg₂ ff    := merge_error' msg₁ msg₂
       | other            := other
       end
     | error msg c := error msg c
     end

instance : monad parser :=
{ bind := @parser.bind, pure := @parser.pure }

def expect (msg : message) (exp : string) : message :=
{expected := [exp], ..msg}

@[inline] def label (p : parser α) (exp : string) : parser α :=
λ it, match p it with
      | ok_eps a it msg := ok_eps a it (expect msg exp)
      | error msg ff    := error (expect msg exp) ff
      | other           := other
      end

infixr ` <?> `:2 := label

/--
`try p` behaves like `p`, but it pretends `p` hasn't
consumed any input when `p` fails.

It is useful for implementing infinite lookahead.
The parser `try p <|> q` will try `q` even when
`p` has consumed input.

It is also useful for specifying both the lexer and parser
together.
```
    (do try (ch 'l' >> ch 'e' >> ch 't'), whitespace, ...)
    <|>
    ...
```
Without the `try` combinator we will not be able to backtrack on the `let` keyword.
-/
def try (p : parser α) : parser α :=
λ it, match p it with
      | error msg _  := error msg ff
      | other        := other
      end

/--
  The `orelse p q` combinator behaves as follows:
  1- If `p` consumed input, then return result produced by `p`
     even if it produced an error.
     Recall that the `try p` combinator can be used to
     pretend that `p` did not consume any input, and
     simulate infinite lookahead.
  2- If `p` did not consume any input, and `q` consumed
     input, then return result produced by `q`.
     Note that, `q`'s result is returned even if
     `p` succeeded without consuming input.
  3- If `p` and `q` did not consume any input, then
     it combines their error messages (even if one of
     them succeeded).
-/
protected def orelse (p q : parser α) : parser α :=
λ it, match p it with
      | ok_eps a it' msg₁ :=
        match q it with
        | ok_eps _ _ msg₂ := merge_ok_epsilon a it' msg₁ msg₂
        | error msg₂ ff   := merge_ok_epsilon a it' msg₁ msg₂
        | other           := other
        end
      | error msg₁ ff :=
        match q it with
        | ok_eps a it' msg₂ := merge_ok_epsilon a it' msg₁ msg₂
        | error msg₂ ff     := merge_error msg₁ msg₂
        | other             := other
        end
      | other               := other
      end

instance : alternative parser :=
{ orelse  := @parser.orelse,
  failure := @parser.failure }

@[inline] def eoi_error (pos : position) : result α :=
error { pos := pos, unexpected := "end of input" } ff

/--
If the next character `c` satisfies `p`, then
update position and return `c`. Otherwise,
generate error message with current position and character.
-/
@[inline] def satisfy (p : char → bool) : parser char :=
λ it, if !it.has_next then
       eoi_error it.offset
      else
        let c := it.curr in
        if !p c then
          error { pos := it.offset, unexpected := repr c } ff
        else
          ok c it.next

def ch (c : char) : parser char :=
satisfy (= c)

def alpha : parser char :=
satisfy char.is_alpha

def digit : parser char :=
satisfy char.is_digit

def upper : parser char :=
satisfy char.is_upper

def lower : parser char :=
satisfy char.is_lower

def any : parser char :=
λ it, if !it.has_next then error { pos := it.offset, unexpected := "end of input" } ff
     else ok it.curr it.next

private def str_aux (s : string) : nat → iterator → iterator → result string
| 0     _    it := ok s it
| (n+1) s_it it :=
  if !it.has_next then eoi_error it.offset
  else if s_it.curr = it.curr then str_aux n s_it.next it.next
       else error { pos := it.offset, unexpected := repr (it.curr) } ff

/--
`str s` parses a sequence of elements that match `s`. Returns the parsed string (i.e. `s`).
This parser consumes no input if it fails (even if a partial match).
Note: The behaviour of this parser is different to that the `string` parser in the Parsec Haskell library,
as this one is all-or-nothing.
-/
def str (s : string) : parser string :=
λ it, if s.is_empty then mk_eps_result "" it
      else str_aux s s.length s.mk_iterator it

private def take_aux : nat → string → iterator →result string
| 0     r it := ok r it
| (n+1) r it :=
  if !it.has_next then eoi_error it.offset
  else take_aux n (r.push (it.curr)) it.next

/-- Consume `n` characters. -/
def take (n : nat) : parser string :=
λ it, if n = 0 then mk_eps_result "" it
      else take_aux n "" it

@[inline] private def mk_string_result (r : string) (it : iterator) : result string :=
if r.is_empty then mk_eps_result r it
else ok r it

private def take_while_aux (p : char → bool) : nat → string → iterator → result string
| 0     r it := mk_string_result r it
| (n+1) r it :=
  if !it.has_next then mk_string_result r it
  else let c := it.curr in
       if p c then take_while_aux n (r.push c) it.next
       else mk_string_result r it

/--
Consume input as long as the predicate returns `tt`, and return the consumed input.
This parser does not fail. It will return an empty string if the predicate
returns `ff` on the current character. -/
def take_while (p : char → bool) : parser string :=
λ it, take_while_aux p it.remaining "" it

/--
Consume input as long as the predicate returns `tt`, and return the consumed input.
This parser requires the predicate to succeed on at least once. -/
def take_while1 (p : char → bool) : parser string :=
λ it, if !it.has_next then eoi_error it.offset
      else let c := it.curr in
           if p c
           then let input := it.next in
                take_while_aux p input.remaining (to_string c) input
           else error { pos := it.offset, unexpected := repr c } ff

/--
Consume input as long as the predicate returns `ff` (i.e. until it returns `tt`), and return the consumed input.
This parser does not fail. -/
def take_until (p : char → bool) : parser string :=
take_while (λ c, !p c)

@[inline] private def mk_consumed_result (consumed : bool) (it : iterator) : result unit :=
if consumed then ok () it
else mk_eps_result () it

private def take_while_aux' (p : char → bool) : nat → bool → iterator → result unit
| 0     consumed it := mk_consumed_result consumed it
| (n+1) consumed it :=
  if !it.has_next then mk_consumed_result consumed it
  else let c := it.curr in
       if p c then take_while_aux' n tt it.next
       else mk_consumed_result consumed it

/-- Similar to `take_while` but it does not return the consumed input. -/
def take_while' (p : char → bool) : parser unit :=
λ it, take_while_aux' p it.remaining ff it

/-- Similar to `take_while1` but it does not return the consumed input. -/
def take_while1' (p : char → bool) : parser unit :=
λ it, if !it.has_next then eoi_error it.offset
      else let c := it.curr in
           if p c
           then let input := it.next in
                take_while_aux' p input.remaining tt input
           else error { pos := it.offset, unexpected := repr c } ff

/-- Consume zero or more whitespaces. -/
def whitespace : parser unit :=
take_while' char.is_whitespace

/-- Shorthand for `p <* whitespace` -/
def lexeme (p : parser α) : parser α :=
p <* whitespace

/-- Parse a numeral in decimal. -/
def num : parser nat :=
string.to_nat <$> (take_while1 char.is_digit)

/-- Return the number of characters left to be parsed. -/
def remaining : parser nat :=
λ it, ok_eps it.remaining it { pos := it.offset }

/-- Succeed only if there are at least `n` characters left. -/
def ensure (n : nat) : parser unit :=
λ it, if n ≤ it.remaining then mk_eps_result () it
      else error { pos := it.offset, unexpected := "end of input", expected := ["at least " ++ to_string n ++ " characters"] } ff

def left_over : parser iterator :=
λ it, ok_eps it it { pos := it.offset }

/-- Return the current position. -/
def pos : parser position :=
λ it, ok_eps it.offset it { pos := it.offset }

def many1_aux (p : parser α) : nat → parser (list α)
| 0     := do a ← p, return [a]
| (n+1) := do a ← p,
              as ← (many1_aux n <|> return []),
              return (a::as)

def many1 (p : parser α) : parser (list α) :=
do r ← remaining, many1_aux p r

def many (p : parser α) : parser (list α) :=
many1 p <* eps

def many1_aux' (p : parser α) : nat → parser unit
| 0     := p >> return ()
| (n+1) := p >> (many1_aux' n <|> return ())

def many1' (p : parser α) : parser unit :=
do r ← remaining, many1_aux' p r

def many' (p : parser α) : parser unit :=
many1' p <* eps

def eoi : parser unit :=
λ it, if it.remaining = 0 then ok_eps () it { pos := it.offset }
      else error { pos := it.offset, unexpected := repr it.curr, expected := ["end of input"] } ff

def sep_by1 (p : parser α) (sep : parser β) : parser (list α) :=
(::) <$> p <*> many (sep >> p)

def sep_by (p : parser α) (sep : parser β) : parser (list α) :=
sep_by1 p sep <|> return []

def fix_aux (f : parser α → parser α) : nat → parser α
| 0     := failure
| (n+1) := f (fix_aux n)

def fix (f : parser α → parser α) : parser α :=
do n ← remaining, fix_aux f (n+1)

/- Parse `p` without consuming any input. -/
def lookahead (p : parser α) : parser α :=
λ it, match p it with
      | ok a s' := ok_eps a it { pos := it.offset }
      | other   := other
      end

def parse (p : parser α) (s : string) (fname := "") : except message α :=
run p s fname

def parse_with_eoi (p : parser α) (s : string) (fname := "") : except message α :=
run (p <* eoi) s fname

def parse_with_left_over (p : parser α) (s : string) (fname := "") : except message (α × iterator) :=
run (prod.mk <$> p <*> left_over) s fname

end lean.parser
