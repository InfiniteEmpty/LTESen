import unittest
from unittest.mock import patch

import numpy as np

from ltesen.ltesync import SyncSupervisor
from ltesen.ltetracking import CsiTracker
from ltesen.ltetracking import csi_tracker as csi_tracker_module
from ltesen.ltetracking.csi_tracker import _butter_lowpass


class CsiTrackerTests(unittest.TestCase):
    @staticmethod
    def _context() -> dict[str, object]:
        return {
            "enb": {"ndlrb": 6, "cell_ref_p": 1},
            "ofdm_info": {"nfft": 128},
            "receive_antenna_count": 1,
        }

    def test_tracker_warms_up_and_removes_static_channel(self) -> None:
        tracker = CsiTracker({"static_filter_order": 0}, self._context())
        csi = np.full((12, 2, 1, 1), 2.0 + 1.0j)
        indices = np.arange(12, dtype=np.int64)[:, None]

        first, first_quality = tracker.correct(csi, csi, indices, indices)
        second, second_quality = tracker.correct(csi, csi, indices, indices)

        self.assertFalse(first_quality["static_estimate_ready"])
        self.assertTrue(second_quality["static_estimate_ready"])
        self.assertEqual(second_quality["timing_delta_lte_samples"], 0)
        np.testing.assert_allclose(first["dynamic_g1"], 0)
        np.testing.assert_allclose(second["dynamic_g1"], 0)
        np.testing.assert_allclose(first["g1"], second["g1"])

    def test_tracker_rejects_wrong_csi_shape(self) -> None:
        tracker = CsiTracker({"static_filter_order": 0}, self._context())
        with self.assertRaises(ValueError):
            tracker.correct(
                np.zeros((12, 1, 1, 1)),
                np.zeros((12, 2, 1, 1)),
                np.arange(12)[:, None],
                np.arange(12)[:, None],
            )

    def test_frame_correction_batches_peak_search_and_updates_once(self) -> None:
        tracker = CsiTracker({"static_filter_order": 0}, self._context())
        csi = np.full((12, 20, 1, 1), 2.0 + 1.0j, dtype=np.complex64)
        indices = np.arange(12, dtype=np.int64)[:, None]

        with patch(
            "ltesen.ltetracking.csi_tracker._estimate_phase_slope_fft",
            wraps=csi_tracker_module._estimate_phase_slope_fft,
        ) as estimator:
            data, quality = tracker.correct_frame(csi, csi, indices, indices)

        self.assertEqual(estimator.call_count, 1)
        self.assertEqual(data["g1"].shape, (12, 20, 1, 1))
        self.assertEqual(data["dynamic_g2"].shape, (12, 20, 1, 1))
        self.assertEqual(quality["static_update_samples"], 20)
        self.assertFalse(quality["static_estimate_ready"])

        _, second_quality = tracker.correct_frame(csi, csi, indices, indices)
        self.assertTrue(second_quality["static_estimate_ready"])

    def test_default_filter_is_stable_at_low_cutoff(self) -> None:
        numerator, denominator = _butter_lowpass(4, np.pi / 512.0)
        poles = np.roots(denominator)
        self.assertLess(float(np.max(np.abs(poles))), 1.0)

        tracker = CsiTracker({}, self._context())
        csi = np.full((12, 2, 1, 1), 2.0 + 1.0j, dtype=np.complex64)
        indices = np.arange(12, dtype=np.int64)[:, None]
        for _ in range(200):
            data, quality = tracker.correct(csi, csi, indices, indices)
        self.assertTrue(np.all(np.isfinite(data["g1"])))
        self.assertTrue(np.isfinite(quality["sample_shift"]))


class SyncSupervisorTests(unittest.TestCase):
    def test_repeated_low_quality_requests_reacquisition(self) -> None:
        supervisor = SyncSupervisor(
            {
                "enable_monitoring": True,
                "suspect_threshold": 0.2,
                "lost_threshold": 0.1,
                "consecutive_failures": 3,
            }
        )
        meta = {"epoch": 1, "raw_end_sample_0": 1234}
        self.assertFalse(supervisor.observe(0.05, meta)["available"])
        self.assertFalse(supervisor.observe(0.05, meta)["available"])
        event = supervisor.observe(0.05, meta)
        self.assertTrue(event["available"])
        self.assertEqual(event["type"], "resync_requested")
        self.assertEqual(event["payload"]["expected_raw_sample_0"], 1234)
        self.assertEqual(supervisor.get_status()["state"], "lost")

    def test_good_quality_clears_failure_count(self) -> None:
        supervisor = SyncSupervisor({"consecutive_failures": 2})
        meta = {"epoch": 1, "raw_end_sample_0": 100}
        supervisor.observe(0.05, meta)
        supervisor.observe(0.5, meta)
        status = supervisor.get_status()
        self.assertEqual(status["state"], "locked")
        self.assertEqual(status["consecutive_failure_count"], 0)


if __name__ == "__main__":
    unittest.main()
