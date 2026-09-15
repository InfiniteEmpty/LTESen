import unittest

import numpy as np

from ltesen.ltetracking.cfo import CfoTracker


class CfoTrackerTests(unittest.TestCase):
    @staticmethod
    def _lock(initial_cfo_hz: float = 0.0) -> dict[str, object]:
        return {
            "ofdm_info": {"nfft": 4, "cyclic_prefix_lengths": (2, 2)},
            "lte_sample_rate_hz": 12000.0,
            "initial_cfo_hz": initial_cfo_hz,
        }

    def test_cp_measurements_are_averaged_before_vector_update(self) -> None:
        tracker = CfoTracker(
            {
                "cfo_refinement_enabled": True,
                "cfo_refinement_interval_subframes": 3,
                "cfo_cp_start_sample": 0,
                "cfo_cp_guard_samples": 0,
            },
            self._lock(),
        )
        frequency_hz = 300.0
        samples = np.arange(12, dtype=np.float64)
        waveform = np.exp(2j * np.pi * frequency_hz * samples / 12000.0).astype(
            np.complex64
        )[:, None]

        for _ in range(2):
            corrected, quality = tracker.correct(waveform)
            self.assertAlmostEqual(quality["cfo_hz"], 0.0, places=5)
            self.assertEqual(quality["cfo_refinement_pending_subframes"], 1 if _ == 0 else 2)
            self.assertTrue(np.all(np.isfinite(corrected)))

        corrected, quality = tracker.correct(waveform)
        self.assertAlmostEqual(quality["cfo_hz"], frequency_hz, places=3)
        self.assertEqual(quality["cfo_refinement_pending_subframes"], 0)
        self.assertAlmostEqual(quality["last_refinement_delta_hz"], frequency_hz, places=3)
        self.assertTrue(np.all(np.isfinite(corrected)))

    def test_refinement_can_be_disabled_for_coarse_only_comparison(self) -> None:
        tracker = CfoTracker(
            {
                "cfo_refinement_enabled": False,
                "cfo_cp_start_sample": 0,
                "cfo_cp_guard_samples": 0,
            },
            self._lock(),
        )
        samples = np.arange(12, dtype=np.float64)
        waveform = np.exp(2j * np.pi * 300.0 * samples / 12000.0).astype(np.complex64)[:, None]
        for _ in range(5):
            tracker.correct(waveform)
        self.assertEqual(tracker.get_status()["cfo_hz"], 0.0)
        self.assertEqual(tracker.get_status()["cfo_refinement_pending_subframes"], 0)


if __name__ == "__main__":
    unittest.main()
