import 'dart:io';

import 'package:intl/intl.dart';

String linuxResponseRgx() =>
    Intl.message(r'from (.*): bytes=(\d+) time=(\d+.?\d+)ms TTL=(\d+)',
        name: 'responseRegex',
        args: [],
        desc: 'Regex used to parse a standard ping response');

String linuxSequenceRgx() => Intl.message(r'icmp_seq=(\d+)',
    name: 'summaryRegex',
    args: [],
    desc:
        'Regex used to parse a sequence ID when a full response is not available');

String linuxSummaryRgx() =>
    Intl.message(r'Sent = (\d+), Received = (\d+), Lost = (\d+)',
        name: 'summaryRegex',
        args: [],
        desc: 'Regex used to parse a ping operation summary');

String macosResponseRgx() =>
    Intl.message(r'from (.*): icmp_seq=(\d+) ttl=(\d+) time=((\d+).?(\d+))',
        name: 'responseRegex',
        args: [],
        desc: 'Regex used to parse a standard ping response');

String macosSequenceRgx() => Intl.message(r'icmp_seq (\d+)',
    name: 'summaryRegex',
    args: [],
    desc:
        'Regex used to parse a sequence ID when a full response is not available');

String macosSummaryRgx() =>
    Intl.message(r'(\d+) packets transmitted, (\d+) received,.*time (\d+)ms',
        name: 'summaryRegex',
        args: [],
        desc: 'Regex used to parse a ping operation summary');

String winResponseRgx() =>
    Intl.message(r'from (.*): bytes=(\d+) time=(\d+.?\d+)ms TTL=(\d+)',
        name: 'responseRegex',
        args: [],
        desc: 'Regex used to parse a standard ping response');

String winSummaryRgx() =>
    Intl.message(r'Sent = (\d+), Received = (\d+), Lost = (\d+)',
        name: 'summaryRegex',
        args: [],
        desc: 'Regex used to parse a ping operation summary');
