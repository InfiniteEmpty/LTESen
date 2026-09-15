import unittest

from tests.helpers.viewer import _is_headless_backend


class ViewerBackendTests(unittest.TestCase):
    def test_gui_backends_are_not_marked_headless(self) -> None:
        self.assertFalse(_is_headless_backend("TkAgg"))
        self.assertFalse(_is_headless_backend("QtAgg"))

    def test_non_gui_backends_are_marked_headless(self) -> None:
        self.assertTrue(_is_headless_backend("Agg"))
        self.assertTrue(_is_headless_backend("pdf"))
        self.assertTrue(
            _is_headless_backend("module://matplotlib_inline.backend_inline")
        )


if __name__ == "__main__":
    unittest.main()
