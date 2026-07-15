import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aurora_downloader/sniffer/browser_controller.dart';
import 'package:aurora_downloader/sniffer/controllers/tab_manager.dart';
import 'package:aurora_downloader/sniffer/media_sniffer_engine.dart';
import 'package:aurora_downloader/sniffer/models/browser_tab.dart';
import 'package:aurora_downloader/sniffer/models/tab_group.dart';
import 'package:aurora_downloader/sniffer/tab_groups/tab_group_palette.dart';

BrowserTab _makeTab(String id) {
  final sniffer = MediaSnifferEngine(client: http.Client());
  final tab = BrowserTab(
    id: id,
    controller: MockBrowserController(),
    snifferEngine: sniffer,
    addressController: TextEditingController(),
  );
  return tab;
}

void _noOp() {}

void main() {
  group('TabGroupPalette', () {
    test('forName is deterministic', () {
      final a = TabGroupPalette.forName('Work');
      final b = TabGroupPalette.forName('Work');
      expect(a, b);
    });

    test('forName is case-insensitive', () {
      expect(
        TabGroupPalette.forName('Work'),
        TabGroupPalette.forName('work'),
      );
      expect(
        TabGroupPalette.forName('Work'),
        TabGroupPalette.forName('WORK'),
      );
    });

    test('forName returns index in range', () {
      for (final name in ['Work', 'Shopping', 'News', 'Research']) {
        final idx = TabGroupPalette.forName(name);
        expect(idx, greaterThanOrEqualTo(0));
        expect(idx, lessThan(TabGroupPalette.swatchCount));
      }
    });

    test('forName empty string returns 0', () {
      expect(TabGroupPalette.forName(''), 0);
      expect(TabGroupPalette.forName('   '), 0);
    });

    test('colorFor honors explicit colorIndex override', () {
      final swatch0 = TabGroupPalette.swatches[0];
      final swatch3 = TabGroupPalette.swatches[3];
      expect(
        TabGroupPalette.colorFor(colorIndex: 0, groupName: 'X'),
        swatch0,
      );
      expect(
        TabGroupPalette.colorFor(colorIndex: 3, groupName: 'X'),
        swatch3,
      );
    });

    test('colorFor falls back to name hash when index is null', () {
      final fromHash = TabGroupPalette.colorFor(
        colorIndex: null,
        groupName: 'Work',
      );
      final fromNameHash = TabGroupPalette.swatches[
          TabGroupPalette.forName('Work')];
      expect(fromHash, fromNameHash);
    });

    test('colorFor treats out-of-range index as null', () {
      final with99 = TabGroupPalette.colorFor(
        colorIndex: 99,
        groupName: 'Work',
      );
      final expected = TabGroupPalette.swatches[
          TabGroupPalette.forName('Work')];
      expect(with99, expected);
    });
  });

  group('TabGroup JSON', () {
    test('round-trip preserves all fields', () {
      final created = DateTime.utc(2026, 7, 15, 10, 30);
      final group = TabGroup(
        name: 'Work',
        colorIndex: 3,
        autoHost: 'jira.atlassian.net',
        sortOrder: 5,
        createdAt: created,
      );
      final json = jsonEncode(group.toJson());
      final restored = TabGroup.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(restored.name, 'Work');
      expect(restored.colorIndex, 3);
      expect(restored.autoHost, 'jira.atlassian.net');
      expect(restored.sortOrder, 5);
      expect(restored.createdAt, created);
    });

    test('fromJson lowercases autoHost', () {
      final group = TabGroup.fromJson(<String, dynamic>{
        'name': 'Work',
        'colorIndex': 0,
        'autoHost': 'JIRA.Atlassian.NET',
        'sortOrder': 0,
        'createdAt': DateTime.now().toIso8601String(),
      });
      expect(group.autoHost, 'jira.atlassian.net');
    });

    test('fromJson handles missing fields gracefully', () {
      final group = TabGroup.fromJson(<String, dynamic>{});
      expect(group.name, '');
      expect(group.colorIndex, TabGroup.unassignedColorIndex);
      expect(group.autoHost, isNull);
      expect(group.sortOrder, 0);
    });

    test('equality uses case-insensitive name', () {
      final a = TabGroup(name: 'Work', createdAt: DateTime.now());
      final b = TabGroup(name: 'work', createdAt: DateTime.now());
      expect(a, b);
    });
  });

  group('TabManager group operations', () {
    late TabManager manager;
    late List<VoidCallback> rebuilds;

    setUp(() {
      rebuilds = <VoidCallback>[];
      manager = TabManager()
        ..onRebuild = () => rebuilds.add(_noOp);
    });

    tearDown(() {
      manager.dispose();
    });

    test('moveTabToGroup creates a new TabGroup on first use', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      expect(manager.tabGroups.length, 1);
      expect(manager.tabGroups.first.name, 'Work');
      expect(tab.groupName, 'Work');
      expect(rebuilds.isNotEmpty, isTrue);
    });

    test('moveTabToGroup reuses existing TabGroup', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      manager.moveTabToGroup(_makeTab('t2'), groupName: 'Work');
      expect(manager.tabGroups.length, 1);
    });

    test('moveTabToGroup removes from group on null', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      manager.moveTabToGroup(tab); // remove
      expect(tab.groupName, isNull);
      expect(tab.groupColorIndex, isNull);
      expect(tab.autoGrouped, isFalse);
    });

    test('moveTabToGroup prunes empty groups', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      expect(manager.tabGroups.length, 1);
      manager.moveTabToGroup(tab); // remove
      expect(manager.tabGroups, isEmpty);
    });

    test('renameGroup cascades to all members', () {
      final t1 = _makeTab('t1');
      final t2 = _makeTab('t2');
      manager.tabs.addAll([t1, t2]);
      manager.moveTabToGroup(t1, groupName: 'Work');
      manager.moveTabToGroup(t2, groupName: 'Work');
      final ok = manager.renameGroup('Work', 'Office');
      expect(ok, isTrue);
      expect(t1.groupName, 'Office');
      expect(t2.groupName, 'Office');
      expect(manager.tabGroups.first.name, 'Office');
    });

    test('renameGroup rejects empty new name', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      final ok = manager.renameGroup('Work', '   ');
      expect(ok, isFalse);
    });

    test('renameGroup rejects collision with another group', () {
      final tab = _makeTab('t1');
      final tab2 = _makeTab('t2');
      manager.tabs.addAll([tab, tab2]);
      manager.moveTabToGroup(tab, groupName: 'Work');
      manager.moveTabToGroup(tab2, groupName: 'Home');
      final ok = manager.renameGroup('Work', 'home');
      expect(ok, isFalse);
      expect(tab.groupName, 'Work');
    });

    test('setGroupColor cascades to members and writes to tab', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      manager.setGroupColor('Work', 3);
      expect(manager.tabGroups.first.colorIndex, 3);
      expect(tab.groupColorIndex, 3);
    });

    test('setGroupColor null reverts to derived', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work', colorIndex: 3);
      manager.setGroupColor('Work', null);
      expect(tab.groupColorIndex, isNull);
    });

    test('setGroupAutoHost stores lowercased host', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      manager.setGroupAutoHost('Work', 'JIRA.ATLASSIAN.NET');
      expect(manager.tabGroups.first.autoHost, 'jira.atlassian.net');
    });

    test('setGroupAutoHost null disables', () {
      final tab = _makeTab('t1');
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      manager.setGroupAutoHost('Work', 'foo.com');
      manager.setGroupAutoHost('Work', null);
      expect(manager.tabGroups.first.autoHost, isNull);
    });

    test('closeGroup closes every member tab and prunes', () {
      final t1 = _makeTab('t1');
      final t2 = _makeTab('t2');
      final t3 = _makeTab('t3');
      manager.tabs.addAll([t1, t2, t3]);
      manager.moveTabToGroup(t1, groupName: 'Work');
      manager.moveTabToGroup(t2, groupName: 'Work');
      manager.moveTabToGroup(t3); // ungrouped
      final closed = manager.closeGroup('Work');
      expect(closed, contains('t1'));
      expect(closed, contains('t2'));
      expect(closed, isNot(contains('t3')));
      expect(manager.tabGroups, isEmpty);
      expect(manager.tabs.length, 1);
      expect(manager.tabs.first.id, 't3');
    });

    test('disbandGroup keeps tabs but removes group', () {
      final t1 = _makeTab('t1');
      final t2 = _makeTab('t2');
      manager.tabs.addAll([t1, t2]);
      manager.moveTabToGroup(t1, groupName: 'Work');
      manager.moveTabToGroup(t2, groupName: 'Work');
      manager.disbandGroup('Work');
      expect(manager.tabGroups, isEmpty);
      expect(manager.tabs.length, 2);
      expect(t1.groupName, isNull);
      expect(t2.groupName, isNull);
    });

    test('reorderTab moves tab and adjusts active index', () {
      final t1 = _makeTab('t1');
      final t2 = _makeTab('t2');
      final t3 = _makeTab('t3');
      manager.tabs.addAll([t1, t2, t3]);
      manager.activeTabIndex = 0;
      manager.reorderTab(0, 3); // move t1 to end
      expect(manager.tabs.map((t) => t.id).toList(), ['t2', 't3', 't1']);
      expect(manager.activeTabIndex, 2);
    });

    test('replaceGroups reorders by sortOrder', () {
      final groups = [
        TabGroup(name: 'B', sortOrder: 1, createdAt: DateTime(2026, 1, 2)),
        TabGroup(name: 'A', sortOrder: 0, createdAt: DateTime(2026, 1, 1)),
      ];
      manager.replaceGroups(groups);
      expect(manager.tabGroups.first.name, 'A');
      expect(manager.tabGroups.last.name, 'B');
    });

    test('moveTabToGroup clears autoGrouped flag', () {
      final tab = _makeTab('t1');
      tab.autoGrouped = true;
      manager.tabs.add(tab);
      manager.moveTabToGroup(tab, groupName: 'Work');
      expect(tab.autoGrouped, isFalse);
    });
  });
}