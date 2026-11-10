#include <lean/lean.h>
#include <pthread.h>
#include <stdlib.h>
#include "sommelier_lean.h"

lean_object *initialize_sommelier_Sommelier_Ffi(uint8_t builtin);
lean_object *sommelier_init(lean_object *);
lean_object *sommelier_step(lean_object *, lean_object *);
lean_object *sommelier_status(lean_object *, lean_object *);
lean_object *sommelier_shown_verdict(lean_object *, lean_object *);
lean_object *sommelier_row_line(lean_object *, lean_object *, lean_object *);
lean_object *sommelier_row_note(lean_object *, lean_object *, lean_object *);
lean_object *sommelier_adopt(lean_object *, lean_object *);
lean_object *sommelier_row_verdict(lean_object *, lean_object *, lean_object *);
lean_object *sommelier_describe_event(lean_object *);
void lean_initialize_runtime_module(void);
void lean_initialize_thread(void);
void lean_finalize_thread(void);

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int init_rc = 1;
static pthread_key_t thread_key;
static _Thread_local int thread_ready = 0;

static void thread_exit(void *p) { (void)p; lean_finalize_thread(); }

static void do_init(void) {
  lean_initialize_runtime_module();
  lean_object *res = initialize_sommelier_Sommelier_Ffi(1);
  if (!lean_io_result_is_ok(res)) { lean_dec_ref(res); init_rc = 1; return; }
  lean_dec_ref(res);
  lean_io_mark_end_initialization();
  pthread_key_create(&thread_key, thread_exit);
  /* the initialising thread is the runtime's "main" thread: already set up, never finalised here */
  thread_ready = 1;
  init_rc = 0;
}

int sm_runtime_init(void) {
  pthread_once(&once, do_init);
  if (init_rc != 0) return init_rc;
  if (!thread_ready) {
    lean_initialize_thread();
    pthread_setspecific(thread_key, (void *)1); /* non-NULL: destructor runs at thread exit */
    thread_ready = 1;
  }
  return 0;
}

static lean_object *mk_arr(const uint32_t *w, size_t n) {
  lean_object *a = lean_alloc_array(n, n);
  for (size_t i = 0; i < n; i++) lean_array_set_core(a, i, lean_usize_to_nat(w[i]));
  return a;
}
/* Copies the Lean answer array into a malloc'd buffer and releases the array.  If malloc fails the array is released (nothing leaks)
   and the answer is "no words" (words == NULL, n == 0): the Swift side reports it as runtimeUnavailable, never as a value. */
static void take_arr(lean_object *a, sm_result *out) {
  size_t n = lean_array_size(a);
  uint32_t *w = (uint32_t *)malloc((n ? n : 1) * sizeof(uint32_t));
  if (w == NULL) { lean_dec(a); out->words = NULL; out->n = 0; return; }
  for (size_t i = 0; i < n; i++) {
    lean_object *v = lean_array_get_core(a, i);
    w[i] = lean_is_scalar(v) ? (uint32_t)lean_unbox(v) : UINT32_MAX; /* answers are small; a bignum cannot occur */
  }
  lean_dec(a);
  out->words = w; out->n = n;
}
static void fail(sm_result *out) { out->words = NULL; out->n = 0; }

sm_state_t sm_init(const uint32_t *r, size_t n) {
  if (sm_runtime_init() != 0) return NULL;
  lean_object *s = sommelier_init(mk_arr(r, n));
  lean_mark_mt(s);
  return (sm_state_t)s;
}

sm_state_t sm_step(sm_state_t s, const uint32_t *ev, size_t n, sm_result *out) {
  if (sm_runtime_init() != 0) { fail(out); lean_inc((lean_object *)s); return s; }
  lean_inc((lean_object *)s);
  lean_object *p = sommelier_step((lean_object *)s, mk_arr(ev, n));
  lean_object *ns = lean_ctor_get(p, 0), *as = lean_ctor_get(p, 1);
  lean_inc(ns); lean_inc(as); lean_dec(p);
  lean_mark_mt(ns);
  take_arr(as, out);
  return (sm_state_t)ns;
}

void sm_status(sm_state_t s, const uint32_t *rd, size_t n, sm_result *out) {
  if (sm_runtime_init() != 0) { fail(out); return; }
  lean_inc((lean_object *)s);
  take_arr(sommelier_status((lean_object *)s, mk_arr(rd, n)), out);
}
void sm_shown_verdict(sm_state_t s, const uint32_t *rd, size_t n, sm_result *out) {
  if (sm_runtime_init() != 0) { fail(out); return; }
  lean_inc((lean_object *)s);
  take_arr(sommelier_shown_verdict((lean_object *)s, mk_arr(rd, n)), out);
}
void sm_row_line(sm_state_t s, const uint32_t *rd, size_t n, const uint32_t *key, size_t nkey, sm_result *out) {
  if (sm_runtime_init() != 0) { fail(out); return; }
  lean_inc((lean_object *)s);
  take_arr(sommelier_row_line((lean_object *)s, mk_arr(rd, n), mk_arr(key, nkey)), out);
}
void sm_row_verdict(sm_state_t s, const uint32_t *rd, size_t n, const uint32_t *key, size_t nkey, sm_result *out) {
  if (sm_runtime_init() != 0) { fail(out); return; }
  lean_inc((lean_object *)s);
  take_arr(sommelier_row_verdict((lean_object *)s, mk_arr(rd, n), mk_arr(key, nkey)), out);
}

void sm_row_note(sm_state_t s, const uint32_t *rd, size_t n, const uint32_t *key, size_t nkey, sm_result *out) {
  if (sm_runtime_init() != 0) { fail(out); return; }
  lean_inc((lean_object *)s);
  take_arr(sommelier_row_note((lean_object *)s, mk_arr(rd, n), mk_arr(key, nkey)), out);
}

void sm_adopt(sm_state_t s, const uint32_t *rd, size_t n, sm_result *out) {
  if (sm_runtime_init() != 0) { fail(out); return; }
  lean_inc((lean_object *)s);
  take_arr(sommelier_adopt((lean_object *)s, mk_arr(rd, n)), out);
}

void sm_describe_event(const uint32_t *ev, size_t n, sm_result *out) {
  if (sm_runtime_init() != 0) { fail(out); return; }
  take_arr(sommelier_describe_event(mk_arr(ev, n)), out);
}

void sm_result_free(sm_result *r) { free(r->words); r->words = NULL; r->n = 0; }
void sm_release(sm_state_t s) { if (s) lean_dec((lean_object *)s); }
