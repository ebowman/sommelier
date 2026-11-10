#ifndef SOMMELIER_LEAN_H
#define SOMMELIER_LEAN_H
/*
 * C shim over the Lean-compiled, PROVED decision core (lean/Sommelier/Ffi.lean).  Words are uint32_t; the Lean side
 * decodes them into the proved types, calls the proved function and encodes the answer.  Every answer starts with a tag
 * word: 0 = ok (payload follows), 1 = the input did not decode (no payload; for sm_step the state is unchanged).
 *
 * Runtime and threads: the Lean runtime is initialised exactly once (pthread_once) by whichever call comes first, and
 * every other thread that calls in is initialised on its first call (and finalised at thread exit).  Callers do nothing.
 * Every state is marked multithreaded when created, so a state may be used from any thread at once (atomic refcounts).
 * States are immutable and persistent: sm_step does NOT consume its input.
 */
#include <stddef.h>
#include <stdint.h>

typedef struct sm_state *sm_state_t;

/* An answer: `n` words at `words` (malloc'd; release with sm_result_free).  words == NULL, n == 0 only if the runtime failed or malloc failed (the Swift side throws .runtimeUnavailable). */
typedef struct { uint32_t *words; size_t n; } sm_result;

/* Idempotent, thread safe.  0 on success. Called implicitly by everything below. */
int sm_runtime_init(void);

/* A new state for the record (n keys).  NULL only if the runtime failed to initialise. Release with sm_release. */
sm_state_t sm_init(const uint32_t *record, size_t n);
/* One step.  Borrows `s`; returns a NEW state (== s retained, if the event is malformed) and the answer in *out. */
sm_state_t sm_step(sm_state_t s, const uint32_t *ev, size_t n, sm_result *out);
void sm_status(sm_state_t s, const uint32_t *rd, size_t n, sm_result *out);
void sm_shown_verdict(sm_state_t s, const uint32_t *rd, size_t n, sm_result *out);
/* `key` is the encoded row key: exactly one word (anything else is malformed and answers tag 1). */
void sm_row_line(sm_state_t s, const uint32_t *rd, size_t n, const uint32_t *key, size_t nkey, sm_result *out);
void sm_row_verdict(sm_state_t s, const uint32_t *rd, size_t n, const uint32_t *key, size_t nkey, sm_result *out);
/* The note beside the row of `key` (same inputs and key rule as sm_row_line): after the ok tag one word, 0 = no note, 1 = noMoveHelps, 2 = cantJudge, 3 = noMoveHere. */
void sm_row_note(sm_state_t s, const uint32_t *rd, size_t n, const uint32_t *key, size_t nkey, sm_result *out);

/* Test support: Lean's reading of an event, as UTF-8 bytes (one per word) after the ok tag. */
void sm_describe_event(const uint32_t *ev, size_t n, sm_result *out);

void sm_result_free(sm_result *r);
void sm_release(sm_state_t s);
#endif
