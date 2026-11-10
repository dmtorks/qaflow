import 'package:qaflow/qaflow.dart';
import 'package:qaflow_protocol/qaflow_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('request round-trips', () {
    final m = HostMessage.decode(const HostRequest(3, 'devices.list', {'a': 1}).encode());
    expect(m, isA<HostRequest>());
    m as HostRequest;
    expect((m.id, m.method), (3, 'devices.list'));
    expect(m.params, {'a': 1});
  });

  test('success response round-trips', () {
    final m = HostMessage.decode(const HostResponse.success(4, {'ok': true}).encode()) as HostResponse;
    expect(m.id, 4);
    expect(m.result, {'ok': true});
    expect(m.error, isNull);
  });

  test('error response round-trips', () {
    final m =
        HostMessage.decode(const HostResponse.failure(5, HostError(HostError.launchFailed, 'no device')).encode())
            as HostResponse;
    expect(m.result, isNull);
    expect(m.error!.code, 1);
    expect(m.error!.message, 'no device');
  });

  test('error data round-trips and names a QaErrorCode', () {
    final m =
        HostMessage.decode(const HostResponse.failure(6, HostError(1, 'nope', {'qaCode': 'unsupported'})).encode())
            as HostResponse;
    expect(m.error!.data, {'qaCode': 'unsupported'});
    expect(m.error!.qaCode, QaErrorCode.unsupported);
    expect(const HostError(1, 'x').qaCode, QaErrorCode.internal);
    expect(const HostError(1, 'x', {'qaCode': 'bogus'}).qaCode, QaErrorCode.internal);
    expect(const HostResponse.failure(7, HostError(1, 'x')).toJson()['error'], {'code': 1, 'message': 'x'});
  });

  test('notification round-trips', () {
    final m = HostMessage.decode(const HostNotification('app.log', {'line': 'x'}).encode());
    expect(m, isA<HostNotification>());
    expect((m as HostNotification).params, {'line': 'x'});
  });

  test('missing params decode as empty', () {
    final m = HostMessage.decode('{"jsonrpc":"2.0","id":1,"method":"hello"}') as HostRequest;
    expect(m.params, isEmpty);
  });

  test('malformed input throws FormatException', () {
    for (final bad in ['not json', '[]', '{}', '{"id":"x","method":"m"}', '{"id":1,"error":{"code":"a"}}']) {
      expect(() => HostMessage.decode(bad), throwsFormatException, reason: bad);
    }
  });

  test('DeviceInfo round-trips for desktop, iOS and Android', () {
    final infos = [
      DeviceInfo.desktop(DevicePlatform.windows, hostOsVersion: '"Windows 10 Pro" 10.0 (Build 19045)'),
      const DeviceInfo(platform: DevicePlatform.ios, name: 'iPhone 17', id: 'UDID-1', osVersion: 'iOS 26.5'),
      const DeviceInfo(
        platform: DevicePlatform.android,
        name: 'Pixel 8',
        id: 'emulator-5554',
        osVersion: 'Android 14 (API 34)',
      ),
    ];
    for (final i in infos) {
      final back = DeviceInfo.fromJson(
        HostMessage.decode(HostNotification('x', i.toJson()).encode()).toJson()['params'] as Map<String, Object?>,
      );
      expect((back.platform, back.name, back.id, back.osVersion), (i.platform, i.name, i.id, i.osVersion));
      expect(back.baselineKey(), i.baselineKey());
    }
  });
}
