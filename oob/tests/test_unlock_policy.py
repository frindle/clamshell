"""Verifier for the unlock decision.

Run: python3 -m unittest discover -s tests -v   (from clamshell/oob)

One branch here is not like the others: injecting a password into an already
unlocked desktop types it into whatever holds focus. Every ambiguous case must
therefore resolve to "send nothing" — a refused unlock costs a walk to the
machine, a leaked password costs a rotation.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from unlock_policy import decide  # noqa: E402


class TestNeverTypeIntoALiveSession(unittest.TestCase):
    def test_unlocked_never_sends(self):
        for ssh in (True, False):
            for hdmi in (True, False, None):
                d = decide(agent="unlocked", ssh_up=ssh, hdmi_signal=hdmi)
                self.assertFalse(d.send, f"must not send: ssh={ssh} hdmi={hdmi}")
                self.assertEqual(d.keys, [])

    def test_unlocked_reason_is_shown_to_the_user(self):
        d = decide(agent="unlocked", ssh_up=True, hdmi_signal=True)
        self.assertTrue(d.reason.strip(), "a refusal must explain itself")


class TestKnownStates(unittest.TestCase):
    def test_locked_sends_password_only(self):
        d = decide(agent="locked", ssh_up=True, hdmi_signal=True)
        self.assertTrue(d.send)
        self.assertEqual(d.keys, ["password"],
                         "the user is already selected at a lock screen")

    def test_login_window_sends_username_then_password(self):
        d = decide(agent=None, ssh_up=True, hdmi_signal=None)
        self.assertTrue(d.send)
        self.assertEqual(d.keys, ["username", "tab", "password"])

    def test_filevault_preboot_sends_password(self):
        # SSH is down (no network stack pre-boot) but the display is live.
        d = decide(agent=None, ssh_up=False, hdmi_signal=True)
        self.assertTrue(d.send)
        self.assertEqual(d.keys, ["password"])


class TestAmbiguityResolvesToSilence(unittest.TestCase):
    def test_powered_off_sends_nothing(self):
        d = decide(agent=None, ssh_up=False, hdmi_signal=False)
        self.assertFalse(d.send)

    def test_unknown_hdmi_sends_nothing(self):
        d = decide(agent=None, ssh_up=False, hdmi_signal=None)
        self.assertFalse(d.send, "cannot distinguish pre-boot from powered off")

    def test_every_non_sending_decision_has_empty_keys(self):
        for agent in ("unlocked", "locked", None):
            for ssh in (True, False):
                for hdmi in (True, False, None):
                    d = decide(agent=agent, ssh_up=ssh, hdmi_signal=hdmi)
                    if not d.send:
                        self.assertEqual(d.keys, [], f"{agent}/{ssh}/{hdmi}")

    def test_unrecognised_agent_state_is_not_treated_as_locked(self):
        # A new or garbled agent status must fail closed, not fall through to
        # the "locked" branch.
        d = decide(agent="sleeping", ssh_up=True, hdmi_signal=True)
        self.assertFalse(d.send)


class TestTotality(unittest.TestCase):
    def test_decide_is_total_over_the_input_space(self):
        for agent in ("unlocked", "locked", None, "", "LOCKED"):
            for ssh in (True, False):
                for hdmi in (True, False, None):
                    d = decide(agent=agent, ssh_up=ssh, hdmi_signal=hdmi)
                    self.assertIsInstance(d.send, bool)
                    self.assertIsInstance(d.keys, list)
                    self.assertIsInstance(d.reason, str)


if __name__ == "__main__":
    unittest.main()
