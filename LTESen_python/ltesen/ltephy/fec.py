"""Small LTE FEC primitives used by the physical-channel layer.

The implementation follows the LTE BCH processing defined by TS 36.212 and
the corresponding srsRAN reference path, but uses ordinary NumPy/Python data
structures rather than the C library's packed buffers and sentinel values.
Soft values use the convention ``LLR > 0`` means that bit 0 is more likely.
"""

from __future__ import annotations

from numbers import Integral, Real
from typing import Any

import numpy as np


_CRC16_POLY = 0x1021
_CONVOLUTIONAL_POLYS = (0x6D, 0x4F, 0x57)
_CONVOLUTIONAL_MEMORY = 6
_CONVOLUTIONAL_STATES = 1 << _CONVOLUTIONAL_MEMORY
_RATE_MATCH_COLUMNS = 32
_RATE_MATCH_PERMUTATION = np.asarray(
    [
        1,
        17,
        9,
        25,
        5,
        21,
        13,
        29,
        3,
        19,
        11,
        27,
        7,
        23,
        15,
        31,
        0,
        16,
        8,
        24,
        4,
        20,
        12,
        28,
        2,
        18,
        10,
        26,
        6,
        22,
        14,
        30,
    ],
    dtype=np.int64,
)
_RATE_MATCH_INVERSE = np.empty_like(_RATE_MATCH_PERMUTATION)
_RATE_MATCH_INVERSE[_RATE_MATCH_PERMUTATION] = np.arange(
    _RATE_MATCH_COLUMNS, dtype=np.int64
)


def lte_crc16(bits: Any) -> int:
    """Return the LTE CRC-16 checksum for an MSB-first bit vector."""

    values = _normalise_bits(bits, "bits")
    state = 0
    for bit in values:
        feedback = ((state >> 15) & 1) ^ int(bit)
        state = (state << 1) & 0xFFFF
        if feedback:
            state ^= _CRC16_POLY
    return state


def append_lte_crc16(bits: Any) -> np.ndarray:
    """Append the 16-bit LTE CRC to an information-bit vector."""

    values = _normalise_bits(bits, "bits")
    checksum = lte_crc16(values)
    crc_bits = np.asarray(
        [(checksum >> shift) & 1 for shift in range(15, -1, -1)], dtype=np.uint8
    )
    return np.concatenate((values, crc_bits))


def lte_bch_crc_mask(ports: int) -> np.ndarray:
    """Return the PBCH CRC mask for 0, 1, 2, or 4 transmit ports."""

    if ports == 0 or ports == 1:
        return np.zeros(16, dtype=np.uint8)
    if ports == 2:
        return np.ones(16, dtype=np.uint8)
    if ports == 4:
        return np.asarray([index % 2 for index in range(16)], dtype=np.uint8)
    raise ValueError("ports must be one of 0, 1, 2, or 4")


def lte_tail_biting_encode(bits: Any) -> np.ndarray:
    """Tail-biting rate-1/3, constraint-length-7 convolutional encoder."""

    values = _normalise_bits(bits, "bits")
    if values.size <= _CONVOLUTIONAL_MEMORY:
        raise ValueError("tail-biting input must contain more than six bits")

    # This is the six-bit shift-register initialization used by srsRAN's
    # tail-biting encoder.  The next state is always the low six bits after a
    # new input bit has entered the seven-bit generator register.
    state = 0
    for bit in values[-_CONVOLUTIONAL_MEMORY:]:
        state = (state << 1) | int(bit)

    encoded = np.empty(values.size * 3, dtype=np.uint8)
    output_index = 0
    for bit in values:
        register = (state << 1) | int(bit)
        for polynomial in _CONVOLUTIONAL_POLYS:
            encoded[output_index] = (register & polynomial).bit_count() & 1
            output_index += 1
        state = register & (_CONVOLUTIONAL_STATES - 1)
    return encoded


def lte_convolutional_rate_match(bits: Any, output_length: int) -> np.ndarray:
    """Rate-match a convolutional codeword using the LTE sub-block layout."""

    values = _normalise_bits(bits, "bits")
    length = _positive_integer(output_length, "output_length")
    if values.size == 0 or values.size % 3:
        raise ValueError("convolutional codeword length must be a non-zero multiple of three")

    data_length = values.size // 3
    rows = (data_length - 1) // _RATE_MATCH_COLUMNS + 1
    columns = rows * _RATE_MATCH_COLUMNS
    dummy = columns - data_length
    null = 100

    # C-major stream order is [v0, v1, v2], with the sub-block interleaver
    # read column-wise after the row-wise write and column permutation.
    interleaved = np.full(3 * columns, null, dtype=np.int64)
    index = 0
    for stream in range(3):
        for column in range(_RATE_MATCH_COLUMNS):
            permuted_column = int(_RATE_MATCH_PERMUTATION[column])
            for row in range(rows):
                source = row * _RATE_MATCH_COLUMNS + permuted_column
                if source >= dummy:
                    interleaved[index] = int(values[(source - dummy) * 3 + stream])
                index += 1

    output = np.empty(length, dtype=np.uint8)
    output_index = 0
    read_index = 0
    while output_index < length:
        if interleaved[read_index] != null:
            output[output_index] = interleaved[read_index]
            output_index += 1
        read_index = (read_index + 1) % interleaved.size
    return output


def lte_convolutional_rate_dematch(
    softbits: Any,
    output_length: int,
) -> np.ndarray:
    """Undo LTE convolutional rate matching and combine repeated soft bits."""

    values = np.asarray(softbits, dtype=np.float64).reshape(-1)
    length = _positive_integer(output_length, "output_length")
    if values.size and not np.all(np.isfinite(values)):
        raise ValueError("softbits must contain finite values")
    if length % 3:
        raise ValueError("output_length must be a multiple of three")

    data_length = length // 3
    rows = (data_length - 1) // _RATE_MATCH_COLUMNS + 1
    columns = rows * _RATE_MATCH_COLUMNS
    dummy = columns - data_length
    null = np.nan
    dematched = np.full(3 * columns, null, dtype=np.float64)

    consumed = 0
    read_index = 0
    while consumed < values.size:
        local = read_index % columns
        column = local // rows
        row = local % rows
        if row * _RATE_MATCH_COLUMNS + int(_RATE_MATCH_PERMUTATION[column]) >= dummy:
            if np.isnan(dematched[read_index]):
                dematched[read_index] = values[consumed]
            else:
                dematched[read_index] += values[consumed]
            consumed += 1
        read_index += 1
        if read_index == dematched.size:
            read_index = 0

    output = np.zeros(length, dtype=np.float64)
    for source in range(data_length):
        row = (source + dummy) // _RATE_MATCH_COLUMNS
        column = (source + dummy) % _RATE_MATCH_COLUMNS
        for stream in range(3):
            location = columns * stream + int(_RATE_MATCH_INVERSE[column]) * rows + row
            if not np.isnan(dematched[location]):
                output[source * 3 + stream] = dematched[location]
    return output


def lte_tail_biting_decode(softbits: Any, frame_length: int) -> np.ndarray:
    """Decode a tail-biting rate-1/3 codeword using max-log Viterbi."""

    values = np.asarray(softbits, dtype=np.float64).reshape(-1)
    length = _positive_integer(frame_length, "frame_length")
    if values.size != length * 3:
        raise ValueError("softbits length must equal three times frame_length")
    if not np.all(np.isfinite(values)):
        raise ValueError("softbits must contain finite values")

    observations = values.reshape(length, 3)

    # Tail-biting means the unknown initial six-bit state is also the final
    # state.  Run all 64 possible starts as one vectorized Viterbi trellis.
    # This keeps the algorithm transparent while avoiding a Python loop over
    # 64 independent decoders for every BCH trial.
    states = np.arange(_CONVOLUTIONAL_STATES, dtype=np.int64)
    branch_scores = np.empty((_CONVOLUTIONAL_STATES, 2), dtype=np.float64)
    for state in states:
        for bit in (0, 1):
            register = (int(state) << 1) | bit
            output = np.asarray(
                [(register & polynomial).bit_count() & 1 for polynomial in _CONVOLUTIONAL_POLYS],
                dtype=np.float64,
            )
            branch_scores[state, bit] = float(np.dot(1.0 - 2.0 * output, observations[0]))

    metrics = np.full(
        (_CONVOLUTIONAL_STATES, _CONVOLUTIONAL_STATES), -np.inf, dtype=np.float64
    )
    diagonal = np.arange(_CONVOLUTIONAL_STATES)
    metrics[diagonal, diagonal] = 0.0
    previous_state = np.empty(
        (length, _CONVOLUTIONAL_STATES, _CONVOLUTIONAL_STATES), dtype=np.int16
    )

    for time in range(length):
        if time:
            for state in states:
                for bit in (0, 1):
                    register = (int(state) << 1) | bit
                    output = np.asarray(
                        [
                            (register & polynomial).bit_count() & 1
                            for polynomial in _CONVOLUTIONAL_POLYS
                        ],
                        dtype=np.float64,
                    )
                    branch_scores[state, bit] = float(
                        np.dot(1.0 - 2.0 * output, observations[time])
                    )
        next_metrics = np.empty_like(metrics)
        for next_state in states:
            bit = int(next_state) & 1
            predecessor0 = int(next_state) >> 1
            predecessor1 = predecessor0 | 32
            score0 = metrics[:, predecessor0] + branch_scores[predecessor0, bit]
            score1 = metrics[:, predecessor1] + branch_scores[predecessor1, bit]
            choose1 = score1 > score0
            next_metrics[:, next_state] = np.where(choose1, score1, score0)
            previous_state[time, :, next_state] = np.where(
                choose1, predecessor1, predecessor0
            )
        metrics = next_metrics

    scores = metrics[diagonal, diagonal]
    start_state = int(np.argmax(scores))
    if not np.isfinite(scores[start_state]):
        raise RuntimeError("tail-biting Viterbi decoding found no cyclic path")
    decoded = np.empty(length, dtype=np.uint8)
    state = start_state
    for time in range(length - 1, -1, -1):
        decoded[time] = state & 1
        state = int(previous_state[time, start_state, state])
    if state != start_state:
        raise RuntimeError("tail-biting Viterbi traceback did not close the cycle")
    return decoded


def _convolutional_trellis() -> tuple[tuple[tuple[int, np.ndarray], tuple[int, np.ndarray]], ...]:
    trellis: list[tuple[tuple[int, np.ndarray], tuple[int, np.ndarray]]] = []
    for state in range(_CONVOLUTIONAL_STATES):
        branches: list[tuple[int, np.ndarray]] = []
        for bit in (0, 1):
            register = (state << 1) | bit
            next_state = register & (_CONVOLUTIONAL_STATES - 1)
            output = np.asarray(
                [(register & polynomial).bit_count() & 1 for polynomial in _CONVOLUTIONAL_POLYS],
                dtype=np.float64,
            )
            branches.append((next_state, output))
        trellis.append((branches[0], branches[1]))
    return tuple(trellis)


def _normalise_bits(value: Any, name: str) -> np.ndarray:
    values = np.asarray(value).reshape(-1)
    if not np.issubdtype(values.dtype, np.number):
        raise TypeError(f"{name} must contain numeric binary values")
    if values.size and (not np.all(np.isfinite(values)) or np.any((values != 0) & (values != 1))):
        raise ValueError(f"{name} must contain only 0 and 1")
    return values.astype(np.uint8, copy=False)


def _positive_integer(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be a positive integer")
    if not np.isfinite(value) or int(value) != value or int(value) < 1:
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


__all__ = [
    "append_lte_crc16",
    "lte_bch_crc_mask",
    "lte_convolutional_rate_dematch",
    "lte_convolutional_rate_match",
    "lte_crc16",
    "lte_tail_biting_decode",
    "lte_tail_biting_encode",
]
