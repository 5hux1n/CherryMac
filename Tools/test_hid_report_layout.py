import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('layout', Path(__file__).with_name('hid-report-layout.py'))
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)

class ReportLayoutTests(unittest.TestCase):
    def test_fields_padding_and_ids(self):
        reports = layout.parse_descriptor(bytes.fromhex('05010906a10185017501950881027508950281018502751095018100c0'))
        self.assertEqual([(r['id'], r['bits'], r['bytesIncludingID']) for r in reports], [(1, 24, 4), (2, 16, 3)])
        self.assertEqual(reports[0]['fields'][1]['offsetBits'], 8)
        self.assertEqual(reports[0]['fields'][1]['flags'], 1)
    def test_push_pop(self):
        reports = layout.parse_descriptor(bytes.fromhex('05010906a101850175089501a4751095029100b48102c0'))
        self.assertEqual([(r['direction'],r['bits']) for r in reports], [('input',8),('output',32)])
    def test_invalid_descriptors(self):
        for data in ['', '75', 'b4', 'c0', 'a101', '8500750895018100', 'fe010000', '0c']:
            with self.subTest(data=data),self.assertRaises(ValueError):layout.parse_descriptor(bytes.fromhex(data))
    def test_local_usage_reset(self):
        reports=layout.parse_descriptor(bytes.fromhex('050c0901a10185037510950119002aff1f81008100c0'))
        self.assertEqual(reports[0]['fields'][0]['local'],{'minimum':0,'maximum':8191})
        self.assertEqual(reports[0]['fields'][1]['local'],{})
    def test_collection_ordinals_distinguish_equal_usages_and_ignore_nesting(self):
        reports=layout.parse_descriptor(bytes.fromhex('061cff0992a101850475089501a1008100c0c00992a10185058100c0'))
        self.assertEqual([r['fields'][0]['topLevelCollectionOrdinal'] for r in reports],[1,2])
        self.assertEqual(reports[0]['fields'][0]['collections'][0],reports[1]['fields'][0]['collections'][0])

if __name__=='__main__':unittest.main()
