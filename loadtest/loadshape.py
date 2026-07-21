# ============================================================================
# loadshape.py — Locust custom LoadTestShape for the ISI-1779 benchmark.
#
# Implements the three-phase load profile Henrik specified (ISI-1779 comment
# 2026-07-21). ONE shape class, the active phase picked by env var LOAD_PHASE
# so each phase runs as a cleanly-bounded, reproducible Locust run and the
# orchestrator (run-benchmark.sh) can gate on app recovery *between* phases:
#
#   LOAD_PHASE=stable30   50 VU, held 30 min                      (baseline)
#   LOAD_PHASE=rampup2h   50 VU + STEP_USERS every STEP_SECS, 2 h (scaling)
#   LOAD_PHASE=leak24h    50 VU, held 24 h                        (memory leak)
#
# The SAME shape is loaded by both app task files (tasks_otel_demo.py and
# tasks_hipster_shop.py) so otel-demo and hipster-shop get an identical VU
# profile at the same wall-clock time — 50 VU "on each app".
#
# Every knob is an env var so DevOps can retune at record time without editing
# code (test-architecture rule: parameters out of the code path).
# ============================================================================
import os

from locust import LoadTestShape


def _int(name, default):
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return int(default)


PHASE = os.environ.get("LOAD_PHASE", "stable30").strip().lower()

BASE_USERS = _int("BASE_USERS", 50)      # 50 VU per app, per Henrik
STEP_USERS = _int("STEP_USERS", 50)      # rampup: +50 VU each step
STEP_SECS = _int("STEP_SECS", 1800)      # rampup: new step every 30 min
SPAWN_RATE = _int("SPAWN_RATE", 5)       # VU/s spawn — gentle, load aligned to traffic
STABLE_SECS = _int("STABLE_SECS", 1800)  # stable30: 30 min
RAMP_SECS = _int("RAMP_SECS", 7200)      # rampup2h: 2 h total
LEAK_SECS = _int("LEAK_SECS", 86400)     # leak24h: 24 h


class BenchmarkShape(LoadTestShape):
    """Env-selected phase. tick() -> (user_count, spawn_rate) or None to stop."""

    def _stable(self, run_time, duration):
        if run_time >= duration:
            return None
        return (BASE_USERS, SPAWN_RATE)

    def _rampup(self, run_time):
        # Step function: start at BASE_USERS, add STEP_USERS at every STEP_SECS
        # boundary, until RAMP_SECS elapses. Default: 50 -> 100 -> 150 -> 200
        # over 4 x 30 min = 2 h (peak held through the final step).
        if run_time >= RAMP_SECS:
            return None
        step = int(run_time // STEP_SECS)
        users = BASE_USERS + step * STEP_USERS
        return (users, SPAWN_RATE)

    def tick(self):
        run_time = self.get_run_time()
        if PHASE == "rampup2h":
            return self._rampup(run_time)
        if PHASE == "leak24h":
            return self._stable(run_time, LEAK_SECS)
        # default / stable30
        return self._stable(run_time, STABLE_SECS)
