import unittest

import numpy as np

from ltesen.ltepipe import Message, Packet, Runtime
from ltesen.lterd import RangeDopplerProcessor, compute_range_doppler


class RangeDopplerTests(unittest.TestCase):
    @staticmethod
    def _context() -> dict[str, object]:
        return {
            "enb": {"ndlrb": 6},
            "ofdm_info": {"nfft": 128},
            "lte_sample_rate_hz": 1.92e6,
            "center_frequency_hz": 900e6,
        }

    def test_fft_map_axes_and_known_peak(self) -> None:
        n_frequency = 12
        n_time = 20
        frequency_bin = 2
        doppler_bin = 3
        frequency = np.arange(n_frequency)[:, None]
        time = np.arange(n_time)[None, :]
        csi = np.exp(
            -2j * np.pi * frequency_bin * frequency / n_frequency
            + 2j * np.pi * doppler_bin * time / n_time
        )

        data, quality = compute_range_doppler(
            csi,
            context=self._context(),
            config={"display_below_noise_db": 10, "display_above_noise_db": 40},
        )
        self.assertEqual(data["complex_map"].shape, (n_frequency, n_time))
        self.assertEqual(data["range_meters"].shape, (n_frequency,))
        self.assertEqual(data["velocity_meters_per_second"].shape, (n_time,))
        peak = np.unravel_index(np.argmax(data["magnitude_db"]), (n_frequency, n_time))
        self.assertEqual(peak, (n_frequency // 2 + frequency_bin, n_time // 2 + doppler_bin))
        self.assertLess(data["velocity_meters_per_second"][1], data["velocity_meters_per_second"][0])
        self.assertEqual(quality["display_limits_db"].shape, (2,))
        self.assertGreater(quality["range_resolution_meters"], 0)

    def test_processor_emits_after_a_complete_window(self) -> None:
        processor = RangeDopplerProcessor(
            {"window_frames": 2, "hop_frames": 2}, context=self._context()
        )
        processor.initialize(Runtime())
        shape = (12, 20, 1, 1)
        for sequence in (0, 10):
            packet = Packet(
                type="csi-frame",
                data={"g1": np.ones(shape, dtype=np.complex128)},
                meta={
                    "epoch": 1,
                    "sequence": sequence,
                    "end_sequence": sequence + 9,
                    "raw_end_sample_0": (sequence + 10) * 100,
                },
                quality={},
            )
            result = processor.process(Message.from_packet(packet))
            if sequence == 0:
                self.assertFalse(result.message.has_packet)
            else:
                self.assertTrue(result.message.has_packet)
                assert result.message.packet is not None
                self.assertEqual(result.message.packet.type, "range-doppler")
                self.assertEqual(result.message.packet.data["magnitude_db"].shape, (12, 40))
        self.assertEqual(processor.output_count, 1)

    def test_missing_center_frequency_is_rejected(self) -> None:
        context = self._context()
        context.pop("center_frequency_hz")
        with self.assertRaises(ValueError):
            RangeDopplerProcessor(context=context).initialize(Runtime())


if __name__ == "__main__":
    unittest.main()
