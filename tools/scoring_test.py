#!/usr/bin/env python3
"""Regression checks for safety-scoring false negatives and mixed rendering."""
from itn_score import ordered_digits as digits

for left, right in [
    ("123 456", "321 456"), ("123 456", "123"),
    ("ISBN 0-300-09751-4", "ISBN 300-9751-4"),
    ("Alice 1 Bob 2", "Alice 2 Bob 1"),
    ("1 2 3", "1 two"), ("one two three", "one two four"),
]:
    assert digits(left) != digits(right), (left, right)
for left, right in [
    ("Class thirty seven quarters", "Class 37/4"),
    ("Class 37 quarters", "Class 37/4"),
    ("DoE Ref two one hundred ninety sixths SZ1666992933", "DoE Ref 2/196 SZ1666992933"),
    ("K9s Four COPs ten K9s", "K9s4 COPs 10 K9s"),
    ("five and three quarters", "5¾"),
    ("twenty five percent Q3", "25% Q3"),
]:
    assert digits(left) == digits(right), (left, right, digits(left), digits(right))
print("PASS ordered numeric scoring: permutations, loss, zeroes, mixed words/digits, fractions")
