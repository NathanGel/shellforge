import pytest
from shellforged.auto_status import MIN_OUTPUT_RATE, QUIET_DONE_SECONDS, SUSTAIN_SECONDS, AutoStatus


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def auto(clock):
    return AutoStatus(clock)


def feed(auto, clock, seconds, rate, state="idle", start_bytes=0, attention=0):
    """Observes once a second for `seconds` at `rate` bytes/s; the states set, in order."""
    out = []
    for i in range(seconds + 1):
        out.append(auto.observe("s", state, start_bytes + int(rate * i), attention))
        clock.now += 1.0
    clock.now -= 1.0
    return out


def test_first_observation_sets_nothing(auto):
    assert auto.observe("s", "idle", 10_000, 5) is None


def test_sustained_output_is_working(auto, clock):
    assert feed(auto, clock, 3, 200)[-1] == "working"


def test_below_rate_is_not_working(auto, clock):
    assert set(feed(auto, clock, 120, 40)) == {None}


def test_burst_shorter_than_sustain_is_not_working(auto, clock):
    seen = [auto.observe("s", "idle", 0, 0)]
    for t in range(1, 40):
        clock.now = float(t)
        seen.append(auto.observe("s", "idle", 5000, 0))
    assert set(seen) == {None}


def working_at_3(auto, clock):
    feed(auto, clock, 3, 200)
    assert clock.now == 3.0


def test_quiet_thirty_seconds_is_done(auto, clock):
    working_at_3(auto, clock)
    clock.now = 3.0 + QUIET_DONE_SECONDS - 0.1
    assert auto.observe("s", "working", 600, 0) is None
    clock.now = 3.0 + QUIET_DONE_SECONDS
    assert auto.observe("s", "working", 600, 0) == "done"


def test_trickling_clock_still_ends_done(auto, clock):
    working_at_3(auto, clock)
    assert MIN_OUTPUT_RATE > 20
    result = []
    for i in range(1, 40):
        clock.now = 3.0 + i
        result.append((clock.now, auto.observe("s", "working", 600 + 20 * i, 0)))
    first = next(t for t, r in result if r == "done")
    # The window still holds the burst for up to SUSTAIN_SECONDS after it, so the quiet starts then.
    assert 3.0 + QUIET_DONE_SECONDS <= first <= 3.0 + SUSTAIN_SECONDS + QUIET_DONE_SECONDS
    assert all(r is None for t, r in result if t < first)


def test_attention_is_needs_input_and_quiet_does_not_end_it(auto, clock):
    auto.observe("s", "idle", 0, 0)
    clock.now = 1.0
    assert auto.observe("s", "idle", 0, 1) == "needsInput"
    clock.now = 100.0
    assert auto.observe("s", "needsInput", 0, 1) is None
    # Sustained output afterwards is working again.
    states = []
    for i in range(1, 5):
        clock.now = 100.0 + i
        states.append(auto.observe("s", "needsInput", 200 * i, 1))
    assert states[-1] == "working"


def test_done_then_sustained_output_is_working(auto, clock):
    working_at_3(auto, clock)
    clock.now = 40.0  # quiet since 3 s
    assert auto.observe("s", "working", 600, 0) == "done"
    states = []
    for t in range(41, 45):
        clock.now = float(t)
        states.append(auto.observe("s", "done", 600 + 200 * (t - 40), 0))
    assert states[:2] == [None, None]
    assert "working" in states


def test_two_samples_far_apart_are_not_sustained(auto, clock):
    auto.observe("s", "idle", 0, 0)
    clock.now = 3.5
    assert auto.observe("s", "idle", 1000, 0) is None


def test_output_going_down_restarts_and_sustained_output_is_working_again(auto, clock):
    for t in range(3):
        clock.now = float(t)
        auto.observe("s", "idle", 200 * t, 0)
    clock.now = 3.0
    assert auto.observe("s", "idle", 0, 0) is None  # a new baseline
    states = []
    for t in range(4, 8):
        clock.now = float(t)
        states.append(auto.observe("s", "idle", 200 * (t - 3), 0))
    assert states[:2] == [None, None] and "working" in states


def test_the_first_attention_count_is_the_baseline(auto, clock):
    assert auto.observe("s", "idle", 0, 5) is None
    clock.now = 1.0
    assert auto.observe("s", "idle", 0, 5) is None
    clock.now = 2.0
    assert auto.observe("s", "idle", 0, 6) == "needsInput"


def test_counter_going_down_restarts_the_baseline(auto, clock):
    auto.observe("s", "idle", 5000, 3)
    clock.now = 1.0
    assert auto.observe("s", "idle", 10, 1) is None
    # The new baseline: a rise from 1 counts, one from 3 would not have.
    clock.now = 2.0
    assert auto.observe("s", "idle", 10, 2) == "needsInput"


def test_none_counters_change_nothing(auto, clock):
    auto.observe("s", "idle", 0, 0)
    clock.now = 50.0
    assert auto.observe("s", "idle", None, None) is None
    assert auto.observe("s", "working", None, None) is None


def test_forget_starts_over(auto, clock):
    auto.observe("s", "idle", 0, 0)
    auto.forget("s")
    clock.now = 1.0
    assert auto.observe("s", "idle", 0, 5) is None
