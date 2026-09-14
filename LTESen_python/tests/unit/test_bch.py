import unittest

import numpy as np

from ltesen.ltephy import lte_bch, lte_bch_decode


class BchTests(unittest.TestCase):
    def test_bch_matches_matlab_reference_vectors(self):
        transport = np.arange(24, dtype=np.uint8) % 2
        references = {
            ("Normal", 1): "111101010010110111100000001010000110100011111111001011010111000000000000010010010000100011010100100111110111101111111110",
            ("Normal", 2): "101111011111111101110100100011000000000111100111111010111110010010001101011000000001000000000110000010111111011011010111",
            ("Normal", 4): "101111011110101101110000000000000110100010110111111010111110000000000001000010010101101001010100100111101101111011010111",
            ("Extended", 4): "101111011110101101110000000000000110100010110111111010111110000000000001000010010101101001010100100111101101111011010111",
        }
        for (prefix, ports), reference in references.items():
            enb = {"CyclicPrefix": prefix, "CellRefP": ports}
            coded = lte_bch(enb, transport)
            self.assertEqual(coded.size, 1728 if prefix == "Extended" else 1920)
            self.assertEqual("".join(str(bit) for bit in coded[:120]), reference)

    def test_partial_rate_matched_bch_decodes_with_each_crc_port_mask(self):
        transport = np.arange(24, dtype=np.uint8) % 2
        for prefix in ("Normal", "Extended"):
            for ports in (1, 2, 4):
                enb = {"CyclicPrefix": prefix, "CellRefP": ports}
                coded = lte_bch(enb, transport)
                quarter = 480 if prefix == "Normal" else 432
                llr = 1.0 - 2.0 * coded[:quarter].astype(np.float64)
                decoded, detected_ports = lte_bch_decode(enb, llr, ports=ports)
                np.testing.assert_array_equal(decoded, transport)
                self.assertEqual(detected_ports, ports)


if __name__ == "__main__":
    unittest.main()
