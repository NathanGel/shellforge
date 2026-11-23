import pytest
from shellforged.models import Usage, UsageWindow
from shellforged.usage import UsageStore, parse_codex_rate_limits, whole_count


def test_store_reports_change_and_snapshot():
    store = UsageStore()
    u = Usage(UsageWindow(23, 1), None, None, "max", 10)
    assert store.set("claude", u) is True
    assert store.set("claude", Usage(UsageWindow(23, 1), None, None, "max", 11)) is False  # only updatedAt differs
    assert store.snapshot() == {"claude": u.to_json() | {"updatedAt": 11}, "codex": None}


def test_store_reports_an_unchanged_usage_once_its_age_moves_a_minute():
    # The footer greys a number by its age, so the client's copy of `updatedAt` must keep up
    # with the daemon's -- once a minute, not once a status-line tick.
    store = UsageStore()
    store.set("codex", Usage(None, UsageWindow(52, 1), None, "team", 1000))
    assert store.set("codex", Usage(None, UsageWindow(52, 1), None, "team", 1059)) is False
    assert store.set("codex", Usage(None, UsageWindow(52, 1), None, "team", 1060)) is True


# Every open Claude session's status line reports the account's limits as of its own last API
# call, every few seconds: an idle one keeps repeating old numbers. Within one window usage only
# grows, so of two reports on the same window the higher is the newer.

def test_an_idle_sessions_older_numbers_never_lower_a_window():
    store = UsageStore()
    store.set("claude", Usage(UsageWindow(54, 1300), UsageWindow(65, 4000), None, None, 10))
    assert store.set("claude", Usage(UsageWindow(46, 1300), UsageWindow(11, 4000), None, None, 15)) is False
    assert store.snapshot()["claude"]["fiveHour"] == {"usedPercent": 54, "resetsAt": 1300}
    assert store.snapshot()["claude"]["sevenDay"] == {"usedPercent": 65, "resetsAt": 4000}


def test_a_higher_number_on_the_same_window_is_news():
    store = UsageStore()
    store.set("claude", Usage(UsageWindow(54, 1300), None, None, None, 10))
    assert store.set("claude", Usage(UsageWindow(55, 1300), None, None, None, 15)) is True
    assert store.snapshot()["claude"]["fiveHour"]["usedPercent"] == 55


def test_a_later_window_replaces_the_old_one_even_when_lower():
    # The 5-hour window reset: the new one starts near zero.
    store = UsageStore()
    store.set("claude", Usage(UsageWindow(90, 1300), None, None, None, 1200))
    assert store.set("claude", Usage(UsageWindow(2, 19300), None, None, None, 1400)) is True
    assert store.snapshot()["claude"]["fiveHour"] == {"usedPercent": 2, "resetsAt": 19300}
    # A session still on the window that ended says nothing new.
    assert store.set("claude", Usage(UsageWindow(88, 1300), None, None, None, 1410)) is False
    assert store.snapshot()["claude"]["fiveHour"] == {"usedPercent": 2, "resetsAt": 19300}


def test_a_report_without_a_window_keeps_the_one_stored_until_it_resets():
    store = UsageStore()
    store.set("claude", Usage(UsageWindow(54, 1300), UsageWindow(65, 4000), None, None, 1000))
    assert store.set("claude", Usage(None, UsageWindow(65, 4000), None, None, 1010)) is False
    assert store.snapshot()["claude"]["fiveHour"] == {"usedPercent": 54, "resetsAt": 1300}
    # Past its reset, a window nobody reports any more is gone.
    assert store.set("claude", Usage(None, UsageWindow(65, 4000), None, None, 1300)) is True
    assert store.snapshot()["claude"]["fiveHour"] is None


def test_a_window_without_a_reset_time_is_taken_as_reported():
    # Nothing to tell its age by: the latest report stands, as before.
    store = UsageStore()
    store.set("codex", Usage(UsageWindow(30, None), None, None, None, 10))
    assert store.set("codex", Usage(UsageWindow(20, None), None, None, None, 11)) is True
    assert store.snapshot()["codex"]["fiveHour"]["usedPercent"] == 20


# The shape below is the `rate_limits` block of a `token_count` event in Codex's own rollout
# file (`~/.codex/sessions/**/rollout-*.jsonl`): snake_case, `used_percent` as a float,
# `window_minutes` as the window's length, `resets_at` in epoch seconds.

def test_parse_codex_windows_by_duration():
    rl = {"primary": {"used_percent": 26.0, "window_minutes": 300, "resets_at": 1789473619},
          "secondary": {"used_percent": 4.0, "window_minutes": 10080, "resets_at": 1789982382}, "plan_type": "team"}
    u = parse_codex_rate_limits(rl, updated_at=5)
    assert u.five_hour == UsageWindow(26, 1789473619) and u.seven_day == UsageWindow(4, 1789982382)
    assert u.plan == "team" and u.updated_at == 5


def test_parse_codex_weekly_only_plan():
    rl = {"primary": {"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1790582049}, "secondary": None,
          "plan_type": "self_serve_business_prolite"}
    u = parse_codex_rate_limits(rl, updated_at=5)
    assert u.five_hour is None and u.seven_day == UsageWindow(52, 1790582049) and u.plan == "self_serve_business_prolite"


def test_parse_codex_unknown_duration_fills_five_hour_first():
    u = parse_codex_rate_limits({"primary": {"used_percent": 3, "window_minutes": 60, "resets_at": None}}, updated_at=1)
    assert u.five_hour == UsageWindow(3, None) and u.seven_day is None
    u = parse_codex_rate_limits({"primary": {"used_percent": 3, "window_minutes": 60},
                                 "secondary": {"used_percent": 7, "window_minutes": 61}}, updated_at=1)
    assert u.five_hour == UsageWindow(3, None) and u.seven_day == UsageWindow(7, None)


def test_parse_codex_rounds_the_percentage():
    u = parse_codex_rate_limits({"primary": {"used_percent": 42.6, "window_minutes": 300}}, updated_at=1)
    assert u.five_hour == UsageWindow(43, None)


def test_parse_codex_tolerates_malformed_fields():
    # The record is another process's output: a window it cannot read is a window it does not have.
    u = parse_codex_rate_limits({"primary": {"used_percent": "84", "window_minutes": 300}}, updated_at=1)
    assert u.five_hour is None and u.seven_day is None
    u = parse_codex_rate_limits({"primary": {"used_percent": 50, "window_minutes": 300, "resets_at": True}}, updated_at=2)
    assert u.five_hour == UsageWindow(50, None)
    u = parse_codex_rate_limits({"primary": {"used_percent": 30, "window_minutes": "300"}}, updated_at=3)
    assert u.five_hour == UsageWindow(30, None) and u.seven_day is None
    u = parse_codex_rate_limits({"primary": ["not", "a", "window"], "plan_type": 7}, updated_at=4)
    assert u.five_hour is None and u.seven_day is None and u.plan is None
    assert parse_codex_rate_limits({}, updated_at=5) == Usage(None, None, None, None, 5)


def test_usage_json_has_exactly_the_wire_fields():
    u = Usage(UsageWindow(1, 2), None, None, "max", 3)
    assert set(u.to_json()) == {"fiveHour", "sevenDay", "spend", "plan", "updatedAt"}


@pytest.mark.parametrize("bad", [float("inf"), float("-inf"), float("nan"), 10 ** 400], ids=["inf", "-inf", "nan", "huge"])
def test_parse_codex_rejects_non_finite_numbers(bad):
    # json.loads accepts Infinity and NaN; int(round()) raises on both, which used to end the tick.
    u = parse_codex_rate_limits({"primary": {"used_percent": bad, "window_minutes": 300}}, updated_at=1)
    assert u.five_hour is None
    u = parse_codex_rate_limits({"primary": {"used_percent": 5, "window_minutes": 300, "resets_at": bad}}, updated_at=1)
    assert u.five_hour == UsageWindow(5, None)


@pytest.mark.parametrize("value,expected", [
    (0, 0), (936_018, 936_018), (12.0, 12),
    (-1, None), (True, None), ("12", None), (None, None), (float("inf"), None), (float("nan"), None),
    # Above 2**53 a double cannot hold every whole number, and 1e30 is no Swift Int at all.
    (2**53, 2**53), (2**53 + 1, None), (1e30, None),
])
def test_a_whole_count_is_a_finite_non_negative_number(value, expected):
    assert whole_count(value) == expected
