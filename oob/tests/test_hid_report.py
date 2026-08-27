"""Verifier for HID keyboard report encoding.

Run: python3 -m unittest discover -s tests -v   (from clamshell/oob)

These pin the cases that make a password type WRONG rather than not at all,
which is the failure that costs a lockout at 2am: repeated characters getting
coalesced, the digit-zero position, and shifted symbols.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hid_report import encode_char, encode_string  # noqa: E402

KEY_UP = bytes(8)
SHIFT = 0x02


class TestEncodeChar(unittest.TestCase):
    def test_lowercase_letters_span_04_to_1d(self):
        self.assertEqual(encode_char("a"), (0x00, 0x04))
        self.assertEqual(encode_char("z"), (0x00, 0x1D))

    def test_uppercase_is_same_code_with_shift(self):
        for lower, upper in (("a", "A"), ("m", "M"), ("z", "Z")):
            _, code = encode_char(lower)
            mod, upper_code = encode_char(upper)
            self.assertEqual(upper_code, code, f"{upper} must reuse {lower}'s usage code")
            self.assertEqual(mod, SHIFT, f"{upper} must set left-shift")

    def test_digits_one_through_nine(self):
        self.assertEqual(encode_char("1"), (0x00, 0x1E))
        self.assertEqual(encode_char("9"), (0x00, 0x26))

    def test_zero_comes_after_nine_not_before_one(self):
        # The classic off-by-one in this table.
        self.assertEqual(encode_char("0"), (0x00, 0x27))

    def test_shifted_symbols_use_the_unshifted_key(self):
        for shifted, unshifted in (("!", "1"), ("@", "2"), ("#", "3"),
                                   ("$", "4"), ("%", "5"), ("^", "6"),
                                   ("&", "7"), ("*", "8"), ("(", "9"),
                                   (")", "0")):
            mod, code = encode_char(shifted)
            _, base = encode_char(unshifted)
            self.assertEqual(mod, SHIFT, f"{shifted} must set shift")
            self.assertEqual(code, base, f"{shifted} must use {unshifted}'s usage code")

    def test_space_is_2c_unshifted(self):
        self.assertEqual(encode_char(" "), (0x00, 0x2C))

    def test_unsupported_character_raises(self):
        # Silently dropping a character types the WRONG password, which is
        # worse than refusing outright.
        for ch in ("é", "€", "\t", "\n"):
            with self.assertRaises(ValueError, msg=f"{ch!r} must raise"):
                encode_char(ch)


class TestEncodeString(unittest.TestCase):
    def test_report_is_eight_bytes_with_one_key(self):
        for report in encode_string("abc"):
            self.assertEqual(len(report), 8)
            self.assertEqual(report[1], 0x00, "byte 1 is reserved and must be zero")
            self.assertEqual(report[3:], bytes(5), "only one key may be pressed at a time")

    def test_sequence_ends_with_key_up(self):
        self.assertEqual(encode_string("abc")[-1], KEY_UP,
                         "sequence must end released, or the last key stays held")

    def test_repeated_characters_get_a_key_up_between_them(self):
        # Without this, the host coalesces and "aa" arrives as "a".
        reports = encode_string("aa")
        _, code = encode_char("a")
        pressed = [i for i, r in enumerate(reports) if r[2] == code]
        self.assertEqual(len(pressed), 2, "both 'a's must be pressed")
        between = reports[pressed[0] + 1:pressed[1]]
        self.assertIn(KEY_UP, between, "a key-up must separate identical consecutive keys")

    def test_distinct_characters_need_no_separator(self):
        # Not required to be minimal, but it must not be pathological either.
        self.assertLessEqual(len(encode_string("ab")), 4)

    def test_mixed_case_password_round_trips(self):
        reports = encode_string("Pa55!")
        codes = [(r[0], r[2]) for r in reports if r != KEY_UP]
        self.assertEqual(codes, [
            encode_char("P"), encode_char("a"), encode_char("5"),
            encode_char("5"), encode_char("!"),
        ])

    def test_empty_string_emits_nothing_or_only_key_up(self):
        self.assertTrue(all(r == KEY_UP for r in encode_string("")))


if __name__ == "__main__":
    unittest.main()
