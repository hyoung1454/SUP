import 'dart:async';
import 'dart:typed_data';

import 'package:animate_icons/animate_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nfree/page/heartbeat/Details_screen.dart';

import 'adpcm_decoder.dart';
import 'animation_custom/circle_transition_router.dart';
import 'test_page/cunk_up_loader.dart';
import 'test_page/nlms_filter.dart';

class BluetoothPage extends StatefulWidget {
  final BluetoothDevice device;

  const BluetoothPage({super.key, required this.device});

  @override
  State<BluetoothPage> createState() =>
      _BluetoothPageState();
}

class _BluetoothPageState extends State<BluetoothPage> {
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final ChunkUploader chunkUploader = ChunkUploader(
    sessionId: "test1",
  );

  // --- Decoders ---
  final AdpcmDecoder _leftDecoder = AdpcmDecoder();
  final AdpcmDecoder _rightDecoder = AdpcmDecoder();

  // --- UUIDs ---
  static const String serviceUuid =
      "00001000-0000-1000-8000-00805f9b34fb";

  // Commands
  static const String commandCharUuid1 =
      "00001001-0000-1000-8000-00805f9b34fb";
  static const String commandCharUuid2 =
      "00001002-0000-1000-8000-00805f9b34fb";
  static const String commandCharUuid3 =
      "00001003-0000-1000-8000-00805f9b34fb"; // 초기화 커맨드
  // Data
  static const String dataCharUuid1 =
      "00001004-0000-1000-8000-00805f9b34fb"; // Left
  static const String dataCharUuid2 =
      "00001005-0000-1000-8000-00805f9b34fb"; // Right
  static const String dataCharUuid3 =
      "00001006-0000-1000-8000-00805f9b34fb";

  // --- 상태 관리 변수들 ---
  List<BluetoothService> _services = [];
  final Map<String, List<int>> _sensorValues = {};
  final Map<String, StreamSubscription<List<int>>?>
  _dataSubscriptions = {};
  String? _activeProfile; // 'profile1' 또는 'profile2'

  // --- NLMS 필터 관련 상태 변수 ---
  final _nlmsFilter = NlmsFilter(
    filterLength: 20,
    mu: 0.002,
    epsilon: 1e-6,
  );
  List<int> _cleanedSignal = [];
  bool _newLeftDataAvailable = false;
  bool _newRightDataAvailable = false;

  // --- 패킷 순서 관리를 위한 상태 변수 ---
  int _leftExpectedNum = 0;
  int _rightExpectedNum = 0;
  static const int _sequenceNumberIndex = 223;

  @override
  void initState() {
    super.initState();
    _connSub = widget.device.connectionState.listen((
      state,
    ) {
      if (mounted &&
          state == BluetoothConnectionState.disconnected) {
        _dataSubscriptions.values.forEach(
          (sub) => sub?.cancel(),
        );
        _dataSubscriptions.clear();
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _dataSubscriptions.values.forEach(
      (sub) => sub?.cancel(),
    );
    chunkUploader.stop(); // 버퍼에 남은 데이터 업로드
    if (widget.device.isConnected) {
      widget.device.disconnect();
    }
    super.dispose();
  }

  // --- BLE 제어 헬퍼 함수 ---

  void _handleDataReceived(
    String dataUuid,
    List<int> value,
  ) {
    if (!mounted || value.isEmpty) return;

    try {
      // 1. 현재 패킷의 시퀀스 번호를 추출합니다.
      final int currentNum = value[_sequenceNumberIndex];
      List<int> newValues;

      // 2. 채널(UUID)에 따라 올바른 로직을 적용합니다.
      if (dataUuid == dataCharUuid1) {
        // Left 채널
        // 3. 패킷 손실 감지 및 복구
        if (currentNum != _leftExpectedNum &&

            _leftExpectedNum != 0) {
          print(
            "--------------left FUCK 패킷 손실-----------------------",
          );
          print(
            "Expected: $_leftExpectedNum, Got: $currentNum",
          );
          _leftDecoder.reset(); // 디코더 리셋
        }
        // 4. 다음 예상 번호 업데이트 (가장 중요!)
        _leftExpectedNum = (currentNum + 1) % 256;

        newValues = _leftDecoder.decode(value); // 디코딩
        _newLeftDataAvailable = true;
      } else if (dataUuid == dataCharUuid2) {
        // Right 채널
        // 3. 패킷 손실 감지 및 복구
        if (currentNum != _rightExpectedNum &&
            _rightExpectedNum != 0) {
          print(
            "--------------right FUCK 패킷 손실-----------------------",
          );
          print(
            "Expected: $_rightExpectedNum, Got: $currentNum",
          );
          _rightDecoder.reset(); // 디코더 리셋
        }
        // 4. 다음 예상 번호 업데이트 (가장 중요!)
        _rightExpectedNum = (currentNum + 1) % 256;

        newValues = _rightDecoder.decode(value); // 디코딩
        _newRightDataAvailable = true;
      } else {
        newValues = List<int>.from(value);
      }

      setState(() => _sensorValues[dataUuid] = newValues);

      // --- 이하 NLMS 필터 처리 로직은 동일 ---
      if (_newLeftDataAvailable && _newRightDataAvailable) {
        final left = _sensorValues[dataCharUuid1];
        final right = _sensorValues[dataCharUuid2];
        if (left != null &&
            right != null &&
            left.length == 224 &&
            right.length == 224) {
          if (left[223] != right[223]) {
            print("씨발 비상");
          }

          final output = _nlmsFilter.process(
            left.map((i) => i.toDouble()).toList(),
            right.map((i) => i.toDouble()).toList(),
          );
          setState(() {
            _cleanedSignal = output;
            chunkUploader.push(output);
          });
        }
        _newLeftDataAvailable = false;
        _newRightDataAvailable = false;
      }
    } catch (e) {
      print('Data parsing error for $dataUuid: $e');
    }
  }

  /// 데이터 수신을 위한 리스너를 시작하는 함수
  Future<void> startListener(String dataUuid) async {
    if (_dataSubscriptions.containsKey(dataUuid)) return;
    if (_services.isEmpty) {
      _services = await widget.device.discoverServices();
    }

    var dataChar = _services
        .expand((s) => s.characteristics)
        .firstWhere((c) => c.uuid == Guid(dataUuid));

    await dataChar.setNotifyValue(true);

    // listen 콜백에서는 데이터를 받아서 처리 함수로 넘겨주기만 합니다.
    final sub = dataChar.onValueReceived.listen((value) {
      _handleDataReceived(dataUuid, value);
    });

    _dataSubscriptions[dataUuid] = sub;
  }

  /// 데이터 수신 리스너를 중지하는 함수
  Future<void> stopListener(String dataUuid) async {
    if (!_dataSubscriptions.containsKey(dataUuid)) return;
    if (_services.isEmpty)
      _services = await widget.device.discoverServices();

    var dataChar = _services
        .expand((s) => s.characteristics)
        .firstWhere((c) => c.uuid == Guid(dataUuid));

    await dataChar.setNotifyValue(false);
    await _dataSubscriptions[dataUuid]?.cancel();
    _dataSubscriptions.remove(dataUuid);
    setState(() {
      _sensorValues.remove(dataUuid);
      if (dataUuid == dataCharUuid1 ||
          dataUuid == dataCharUuid2) {
        _cleanedSignal = [];
        chunkUploader.stop();
      }
    });
  }

  /// 커맨드 특성에 값을 쓰는 함수
  Future<void> writeCommand(
    String commandUuid,
    int value,
  ) async {
    if (_services.isEmpty)
      _services = await widget.device.discoverServices();
    var commandChar = _services
        .expand((s) => s.characteristics)
        .firstWhere((c) => c.uuid == Guid(commandUuid));
    // 표준 '응답 있는 쓰기' 방식으로 되돌림
    await commandChar.write([value]);
  }

  // --- 프로필 제어 함수 ---

  Future<void> startProfile1() async {
    if (_activeProfile != null) return;
    _toast('프로필 1 시작 중...');
    try {
      // 상태 변수 및 디코더 초기화
      _leftExpectedNum = 0;
      _rightExpectedNum = 0;
      _leftDecoder.reset();
      _rightDecoder.reset();

      await startListener(dataCharUuid1);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await startListener(dataCharUuid2);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await writeCommand(commandCharUuid1, 1);
      setState(() => _activeProfile = 'profile1');
      _toast('프로필 1 시작 완료');
    } catch (e) {
      _toast('프로필 1 시작 오류: $e');
      await stopProfile1(showToast: false); // 실패 시 정리
    }
  }

  Future<void> stopProfile1({bool showToast = true}) async {
    if (showToast) _toast('프로필 1 중단 중...');
    try {
      await writeCommand(commandCharUuid1, 0);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await stopListener(dataCharUuid1);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await stopListener(dataCharUuid2);
      if (showToast) _toast('프로필 1 중단 완료');
    } catch (e) {
      if (showToast) _toast('프로필 1 중단 중 오류 발생: $e');
      print('Error stopping profile 1: $e');
    } finally {
      // 오류 발생 여부와 상관없이 항상 UI 상태를 리셋
      setState(() => _activeProfile = null);
    }
  }

  Future<void> startProfile2() async {
    if (_activeProfile != null) return;
    _toast('프로필 2 시작 중...');
    try {
      // 상태 변수 및 디코더 초기화
      _leftExpectedNum = 0;
      _rightExpectedNum = 0;
      _leftDecoder.reset();
      _rightDecoder.reset();

      await startListener(dataCharUuid1);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await startListener(dataCharUuid2);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await startListener(dataCharUuid3);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await writeCommand(commandCharUuid2, 1);
      setState(() => _activeProfile = 'profile2');
      _toast('프로필 2 시작 완료');
    } catch (e) {
      _toast('프로필 2 시작 오류: $e');
      await stopProfile2(showToast: false); // 실패 시 정리
    }
  }

  Future<void> stopProfile2({bool showToast = true}) async {
    if (showToast) _toast('프로필 2 중단 중...');
    try {
      await writeCommand(commandCharUuid2, 0);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await stopListener(dataCharUuid1);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await stopListener(dataCharUuid2);
      await Future.delayed(
        const Duration(milliseconds: 200),
      );
      await stopListener(dataCharUuid3);
      if (showToast) _toast('프로필 2 중단 완료');
    } catch (e) {
      if (showToast) _toast('프로필 2 중단 중 오류 발생: $e');
      print('Error stopping profile 2: $e');
    } finally {
      // 오류 발생 여부와 상관없이 항상 UI 상태를 리셋
      setState(() => _activeProfile = null);
    }
  }

  // --- 추가된 초기화 커맨드 함수 ---
  Future<void> _sendResetCommand() async {
    try {
      _toast('필터 초기화 커맨드 전송 중...');
      await writeCommand(commandCharUuid3, 1);
      _toast('초기화 커맨드 전송 완료');
    } catch (e) {
      _toast('초기화 커맨드 오류: $e');
      print('Error sending reset command: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // 버튼의 위치를 가져오기 위해 GlobalKey를 생성합니다.
  final GlobalKey buttonKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            SizedBox(
              width: 60,
              height: 60,
              child: ElevatedButton(
                key: buttonKey,
                onPressed: () {
                  // 버튼의 RenderBox를 찾습니다.
                  final renderBox =
                  buttonKey.currentContext
                      ?.findRenderObject()
                  as RenderBox?;
                  if (renderBox == null) return;

                  // RenderBox를 통해 버튼의 크기와 화면상 위치를 계산합니다.
                  final size = renderBox.size;
                  final position = renderBox.localToGlobal(
                    Offset.zero,
                  );

                  // 버튼의 중심 좌표를 계산합니다.
                  final buttonCenter = Offset(
                    position.dx + size.width / 2,
                    position.dy + size.height / 2,
                  );

                  // Navigator.push를 사용하여 커스텀 라우트를 실행하고, 계산된 중심 좌표를 전달합니다.
                  // Navigator.of(context).push(
                  //   CircleTransitionRoute(
                  //     page: const DetailsScreen(),
                  //     startCenter: buttonCenter,
                  //   ),
                  // );

                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  shape: const CircleBorder(),
                  // 버튼 모양을 원형으로
                  padding: EdgeInsets.zero,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  size: 30,
                  color: Colors.white,
                ),
              ),
            ),
            _buildInfoCard(),
            const SizedBox(height: 20),
            _buildControlCard(),
            const SizedBox(height: 20),
            _buildDataCard(),
            const SizedBox(height: 20),
            _buildNlmsOutputCard(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '기기 정보',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(),
            Text('이름: ${widget.device.platformName}'),
            const SizedBox(height: 8),
            Text('ID: ${widget.device.remoteId.str}'),
            const SizedBox(height: 8),
            StreamBuilder<BluetoothConnectionState>(
              stream: widget.device.connectionState,
              initialData:
                  BluetoothConnectionState.connecting,
              builder: (c, snapshot) {
                final stateText = snapshot.data
                    .toString()
                    .split('.')
                    .last;
                return Text('상태: $stateText');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '프로필 제어',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(),
            _buildProfileControlRow(
              "프로필 1 (L/R)",
              'profile1',
              startProfile1,
              stopProfile1,
            ),
            const Divider(),
            _buildProfileControlRow(
              "프로필 2 (L/R/S)",
              'profile2',
              startProfile2,
              stopProfile2,
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 8.0,
              ),
              child: Center(
                child: ElevatedButton(
                  onPressed: _sendResetCommand,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                  child: const Text(
                    '필터 초기화',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
            const Divider(), // 새로 추가된 구분선
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 8.0,
              ),
              child: Center(
                child: ElevatedButton(
                  onPressed: () {
                    _toast('수동 데이터 수신 시작...');
                    startListener(dataCharUuid1);
                    startListener(dataCharUuid2);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                  ),
                  child: const Text(
                    '수동 데이터 수신 테스트',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ), // 새로 추가된 버튼
          ],
        ),
      ),
    );
  }

  Widget _buildProfileControlRow(
    String title,
    String profileIdentifier,
    VoidCallback onStart,
    VoidCallback onStop,
  ) {
    final bool isAnyProfileActive = _activeProfile != null;
    final bool isThisProfileActive =
        _activeProfile == profileIdentifier;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: isAnyProfileActive
                    ? null
                    : onStart,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                ),
                child: const Text(
                  'Start',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: isThisProfileActive
                    ? onStop
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                ),
                child: const Text(
                  'Stop',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDataCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '실시간 수신 데이터',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(),
            _buildDataDisplay(
              "Stream 1 (Left)",
              dataCharUuid1,
            ),
            const Divider(),
            _buildDataDisplay(
              "Stream 2 (Right)",
              dataCharUuid2,
            ),
            const Divider(),
            _buildDataDisplay("Stream 3", dataCharUuid3),
          ],
        ),
      ),
    );
  }

  Widget _buildDataDisplay(String title, String dataUuid) {
    final values = _sensorValues[dataUuid] ?? [];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$title (${values.length}개)',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          if (values.isNotEmpty)
            SizedBox(
              height: 100,
              child: SingleChildScrollView(
                child: Text(
                  // values.map((v) => '0x${v.toRadixString(16).padLeft(2, '0')}').join(', '),
                  values.join(', '),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            )
          else
            const Text('수신된 데이터가 없습니다.'),
        ],
      ),
    );
  }

  Widget _buildNlmsOutputCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NLMS 필터 출력 (노이즈 제거 신호)',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(),
            const SizedBox(height: 8),
            if (_cleanedSignal.isNotEmpty)
              SizedBox(
                height: 150,
                child: SingleChildScrollView(
                  child: Text(
                    _cleanedSignal
                        .map((d) => d.toString())
                        .join(', '),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              )
            else
              const Text('필터링된 데이터가 없습니다.'),
          ],
        ),
      ),
    );
  }
}
