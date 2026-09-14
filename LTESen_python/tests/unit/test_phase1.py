from __future__ import annotations

import math
import unittest

import numpy as np

from ltesen.config import load_config
from ltesen.ltebuffer import CsiFrameAssembler, FrameWindow
from ltesen.lteio import processing_sample_rate
from ltesen.ltepipe import Message, Module, Packet, Pipeline, Result


def make_subframe(epoch: int, sequence: int, subframe_number: int) -> Packet:
    value = float(subframe_number)
    return Packet(
        type="csi-subframe",
        data={
            "g1": np.full((1, 2, 1, 1), value),
            "g2": np.full((1, 2, 1, 1), value + 20),
            "dynamic_g1": np.full((1, 2, 1, 1), value + 40),
            "dynamic_g2": np.full((1, 2, 1, 1), value + 60),
        },
        meta={
            "epoch": epoch,
            "sequence": sequence,
            "subframe_number": subframe_number,
            "frame_number": sequence // 10,
            "raw_start_sample_0": sequence * 100,
            "raw_end_sample_0": (sequence + 1) * 100,
        },
        quality={},
    )


def make_frame(sequence: int, frame_index: int, receive_count: int = 2) -> Packet:
    values = np.zeros((1, 2, receive_count, 1))
    for receive in range(receive_count):
        values[:, :, receive, :] = frame_index + 100 * receive
    return Packet(
        type="csi-frame",
        data={"g1": values},
        meta={
            "epoch": 1,
            "sequence": sequence,
            "end_sequence": sequence + 9,
        },
        quality={},
    )


class ScriptedSource(Module):
    def __init__(self, steps: list[Result]) -> None:
        super().__init__("source", None, "test")
        self.steps = steps

    def process(self, message: Message) -> Result:
        del message
        return self.steps.pop(0)


class Probe(Module):
    def __init__(self) -> None:
        super().__init__("probe", "test", "test")
        self.reset_count = 0
        self.packet_count = 0
        self.artifact_count = 0
        self.last_reset: dict[str, object] | None = None

    def process(self, message: Message) -> Result:
        self.validate_input(message)
        if message.has_packet:
            self.packet_count += 1
        self.artifact_count += len(message.artifacts)
        return Result.forward(message)

    def reset(self, event: dict[str, object] | None = None) -> None:
        self.reset_count += 1
        self.last_reset = event


class FinalizeEmitter(Module):
    def __init__(self) -> None:
        super().__init__("emitter", None, "")

    def process(self, message: Message) -> Result:
        return Result.forward(message)

    def finalize(self, reason: str) -> Result:
        del reason
        artifact = {
            "type": "test-artifact",
            "data": {},
            "meta": {},
        }
        return Result.forward(Message.none().add_artifact(artifact))


class PhaseOneTests(unittest.TestCase):
    def test_default_yaml_has_python_schema_and_override(self) -> None:
        config = load_config(overrides={"display": {"enabled": False}})
        self.assertFalse(config["display"]["enabled"])
        self.assertEqual(config["acquisition"]["initial_ndlrb"], 6)
        self.assertIsNone(config["execution"]["maximum_iterations"])

    def test_processing_rate_is_snapped(self) -> None:
        self.assertEqual(processing_sample_rate(15360000.011967678), 15360000)
        with self.assertRaises(ValueError):
            processing_sample_rate(math.nan)

    def test_assembler_emits_only_complete_frame(self) -> None:
        assembler = CsiFrameAssembler()
        for subframe in range(9):
            result = assembler.process(
                Message.from_packet(make_subframe(1, subframe, subframe))
            )
            self.assertFalse(result.message.has_packet)
        result = assembler.process(Message.from_packet(make_subframe(1, 9, 9)))
        self.assertTrue(result.message.has_packet)
        assert result.message.packet is not None
        np.testing.assert_array_equal(
            result.message.packet.data["g1"].reshape(-1),
            np.repeat(np.arange(10), 2),
        )
        self.assertEqual(result.message.packet.meta["end_sequence"], 9)
        self.assertEqual(result.message.packet.quality["subframe_count"], 10)

    def test_assembler_does_not_bridge_sequence_gap(self) -> None:
        assembler = CsiFrameAssembler()
        for subframe in range(4):
            assembler.process(Message.from_packet(make_subframe(1, subframe, subframe)))
        result = assembler.process(Message.from_packet(make_subframe(1, 5, 5)))
        self.assertFalse(result.message.has_packet)
        self.assertEqual(assembler.buffered_subframes, 0)
        self.assertEqual(assembler.dropped_partial_frames, 1)
        for subframe in range(10):
            result = assembler.process(
                Message.from_packet(make_subframe(1, 10 + subframe, subframe))
            )
        self.assertTrue(result.message.has_packet)
        assert result.message.packet is not None
        self.assertEqual(result.message.packet.meta["sequence"], 10)

    def test_frame_window_preserves_time_order_and_antennas(self) -> None:
        window = FrameWindow(3, 3)
        result = WindowResultProxy()
        for frame_index in range(3):
            result.value = window.push(make_frame(frame_index * 10, frame_index))
        self.assertTrue(result.value.available)
        assert result.value.data is not None
        self.assertEqual(result.value.data.shape, (1, 6, 2, 1))
        np.testing.assert_array_equal(
            result.value.data[0, :, 0, 0], [0, 0, 1, 1, 2, 2]
        )
        np.testing.assert_array_equal(
            result.value.data[0, :, 1, 0], [100, 100, 101, 101, 102, 102]
        )

    def test_pipeline_routes_reset_stop_and_final_artifacts(self) -> None:
        packet = Packet("test", {"value": 1}, {"epoch": 2}, {})
        source = ScriptedSource(
            [
                Result.reset_downstream(Message.none(), 2, "test-gap"),
                Result.emit(packet),
                Result.stop(Message.none(), "end-of-file"),
            ]
        )
        probe = Probe()
        pipeline = Pipeline({"maximum_iterations": 10, "verbose": False})
        pipeline.register(source)
        pipeline.register(probe)
        summary = pipeline.run()
        self.assertEqual(summary["iterations"], 3)
        self.assertEqual(summary["termination_reason"], "end-of-file")
        self.assertEqual(probe.reset_count, 1)
        self.assertEqual(probe.packet_count, 1)
        self.assertEqual(probe.last_reset["source"], "source")  # type: ignore[index]

        source2 = ScriptedSource([])
        emitter = FinalizeEmitter()
        probe2 = Probe()
        final_pipeline = Pipeline({"verbose": False})
        final_pipeline.register(source2)
        final_pipeline.register(emitter)
        # An empty output type is intentionally a transparent stage.
        final_pipeline.register(probe2)
        artifacts = final_pipeline.finalize("completed")
        self.assertEqual(len(artifacts), 1)
        self.assertEqual(artifacts[0]["type"], "test-artifact")
        self.assertEqual(probe2.artifact_count, 1)
        self.assertEqual(final_pipeline.finalize("ignored"), artifacts)


class WindowResultProxy:
    def __init__(self) -> None:
        self.value = None


if __name__ == "__main__":
    unittest.main()
