"""Test discovery runners are put here. Currently only the global runner is here."""

from collections.abc import Sequence
from unittest import TestSuite

from django.test.runner import DiscoverRunner


class GlobalTestRunner(DiscoverRunner):
    """Custom test runner to discover root level test folder."""

    def build_suite(self, test_labels: Sequence[str] | None = None) -> TestSuite:
        """Add the tests root folder into the test runner."""
        if test_labels and "tests" not in test_labels:
            test_labels += ["tests"]

        return super().build_suite(test_labels)
