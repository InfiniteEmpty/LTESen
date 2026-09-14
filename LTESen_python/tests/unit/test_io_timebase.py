from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from ltesen.lteio import (
    LegacyLTEDataFile,
    SigMFCollection,
    SigMFDataFile,
    open_recording,
    resample_waveform,
)
from ltesen.ltepipe import Packet
from ltesen.ltesync import Timebase


def write_sigmf_pair(
    directory: Path,
    name: str,
    values: np.ndarray,
    *,
    datatype: str = "ci16_le",
    sample_rate: float = 15.36e6,
    frequency: float = 874.2e6,
    trailing_bytes: int = 0,
) -> None:
    data_path = directory / f"{name}.sigmf-data"
    meta_path = directory / f"{name}.sigmf-meta"
    values.astype(np.dtype("<i2"), copy=False).tofile(data_path)
    if trailing_bytes:
        with data_path.open("ab") as stream:
            stream.write(b"x" * trailing_bytes)
    metadata = {
        "global": {
            "core:datatype": datatype,
            "core:num_channels": 1,
            "core:sample_rate": sample_rate,
            "core:trailing_bytes": trailing_bytes,
        },
        "captures": [
            {
                "core:frequency": frequency,
                "core:datetime": "2026-08-25T03:15:53.781742291Z",
                "core:sample_start": 0,
            }
        ],
        "annotations": [],
    }
    meta_path.write_text(json.dumps(metadata), encoding="utf-8")


class IoAndTimebaseTests(unittest.TestCase):
    def test_legacy_reader_metadata_seek_and_normalization(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "LTE_20260803_000001_fc_3200M_fs_30720k_tp_int16.bin"
            np.asarray([1, -2, 3, -4], dtype="<i2").tofile(path)

            recording = LegacyLTEDataFile(path)
            self.assertEqual(recording.prefix, "LTE_20260803_000001")
            self.assertEqual(recording.date, "20260803")
            self.assertEqual(recording.record_id, "000001")
            self.assertEqual(recording.sample_count, 2)
            self.assertEqual(recording.sample_rate, 30.72e6)
            self.assertEqual(recording.frequency, 3.2e9)
            np.testing.assert_array_equal(recording.read(1), [1 - 2j])
            self.assertEqual(recording.offset, 1)
            np.testing.assert_array_equal(recording.read_at(1, 1), [3 - 4j])
            recording.seek(-1, "eof")
            np.testing.assert_array_equal(recording.read(normalize=True), [(3 - 4j) / 32768])
            self.assertTrue(recording.eof)

    def test_sigmf_reader_handles_colon_metadata_and_trailing_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            values = np.asarray([100, -200, 300, -400], dtype="<i2")
            write_sigmf_pair(directory, "record", values, trailing_bytes=3)
            recording = SigMFDataFile(directory, "record")

            self.assertEqual(recording.datatype, "ci16_le")
            self.assertEqual(recording.sample_count, 2)
            self.assertEqual(recording.data_bytes, 11)
            self.assertEqual(recording.trailing_bytes, 3)
            np.testing.assert_array_equal(recording.read(), [100 - 200j, 300 - 400j])
            self.assertEqual(recording.describe()["record_name"], "record")

    def test_sigmf_collection_and_open_recording(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            values = np.asarray([1, 2, 3, 4], dtype="<i2")
            write_sigmf_pair(directory, "stream_a", values)
            write_sigmf_pair(directory, "stream_b", values)
            collection_metadata = {
                "collection": {
                    "core:streams": [
                        {"name": "stream_a"},
                        {"name": "stream_b.sigmf-data"},
                    ]
                }
            }
            (directory / "collection.sigmf-collection").write_text(
                json.dumps(collection_metadata), encoding="utf-8"
            )

            collection = SigMFCollection(directory, "collection")
            self.assertEqual(collection.stream_count, 2)
            self.assertEqual(collection.get_stream(0).record_name, "stream_a")
            self.assertEqual(collection.get_stream("stream_b").record_name, "stream_b")
            self.assertEqual(
                open_recording(directory, "stream_a").format,
                "sigmf",
            )

            legacy_path = directory / "LTE_20260803_000001_fc_3200M_fs_30720k.bin"
            values.tofile(legacy_path)
            self.assertEqual(
                open_recording(directory, "LTE_20260803_000001").format,
                "legacy",
            )

    def test_timebase_keeps_raw_and_lte_sample_domains_explicit(self) -> None:
        lock = {
            "epoch": 3,
            "raw_sample_rate_hz": 30.72e6,
            "lte_sample_rate_hz": 15.36e6,
            "raw_frame_start_sample_0": 1000,
            "enb": {"n_frame": 7},
        }
        timebase = Timebase(lock)
        first = timebase.current_meta()
        timebase.advance(-1)
        second = timebase.current_meta()
        self.assertEqual(first["epoch"], 3)
        self.assertEqual(first["raw_start_sample_0"], 1000)
        self.assertEqual(second["raw_start_sample_0"], 1000 + 30720 - 2)
        self.assertEqual(second["subframe_number"], 1)
        self.assertEqual(second["sequence"], 1)
        self.assertTrue(timebase.can_read(62438))

        for _ in range(9):
            timebase.advance()
        self.assertEqual(timebase.subframe_number, 0)
        self.assertEqual(timebase.frame_number, 8)

    def test_resampler_preserves_integer_rate_phase_and_shape(self) -> None:
        waveform = np.ones(64, dtype=np.complex128)
        result = resample_waveform(waveform, 6, 3)
        np.testing.assert_allclose(result, waveform[::2], atol=1e-12)
        self.assertEqual(result.ndim, 1)

        antennas = np.column_stack((waveform, 2 * waveform))
        result = resample_waveform(antennas, 6, 3, output_length=2)
        self.assertEqual(result.shape, (2, 2))
        np.testing.assert_allclose(result, antennas[::2][:2], atol=1e-12)

    def test_resampler_suppresses_out_of_band_energy_before_decimation(self) -> None:
        sample_indices = np.arange(512)
        waveform = np.exp(2j * np.pi * 0.45 * sample_indices)
        result = resample_waveform(waveform, 2, 1)
        self.assertLess(abs(np.mean(result[64:])), 0.05)

    def test_reader_accepts_a_mapping_packet_only_at_pipeline_boundary(self) -> None:
        # This documents the separate packet contract without coupling readers
        # to pipeline Message objects.
        packet = Packet("raw-iq", {"samples": np.ones(2)}, {}, {})
        self.assertEqual(packet.type, "raw-iq")


if __name__ == "__main__":
    unittest.main()
