// =============================================================================
// 🌱 自力 —— 自律番茄钟（Flutter 安卓应用 · 完整单文件版 v1.1）
// -----------------------------------------------------------------------------
// v1 功能：三种计时模式（25/5/15 分钟，可自定义）/ 开始·暂停·重置·跳过 /
//          大号数字 + 圆形进度环 / 番茄计数（每 4 个自动长休息）/
//          震动 + 提示音 / 本地持久化 / 后台计时（精确闹钟通知）
// v1.1 新增（本次改动）：
//   ① 任务模块      —— 可创建多个任务，每个任务独立自定义"番茄钟参数"
//                      （名称 + 工作时长 + 短休 + 长休），打开任务直接沿用配置
//   ② 自律打卡模块  —— 自定义每日打卡项（早起/跑步/读书…），按天打勾、
//                      显示连续天数与最近 7 天记录
//   ③ 时间统计模块  —— 每个任务的累计专注时长，扇形图 + 图下明细标注
//   ④ 全新 App 图标 —— 绿色渐变 + 白色圆环对勾（见 res/ 与 scripts/gen_icon.py）
//   ⑤ 底部导航栏    —— 计时 / 任务 / 打卡 / 统计，四个页面像微信一样切换
//
// v1.3 修复 / 新增：
//   · 修复统计时长虚高：记账改为「秒表式累计」——已用时间由累计器直接推导，
//     不再用「总时长 - 剩余时长」估算（旧逻辑在会话基准与总时长不一致时，
//     会把 40 分钟任务跳过后记成 39 分钟）。现在一律按【实际用时】精确记账。
//   · 新增「正计时」（自由计时）：不限时长正向计时，结束 / 重置时按实际用时记账。
//
// v1.4 更新：
//   · 任务可选计时方式：新建 / 编辑任务时可选择「倒计时（番茄钟）」或
//     「正计时（自由计时）」，打开该任务后自动采用对应方式；
//   · 默认番茄钟也可在计时页右上角的"任务设置"里切换计时方式。
// -----------------------------------------------------------------------------
// 代码结构（单文件，按 9 个区块组织，建议配合 IDE 大纲视图阅读）：
//   【一】模型与工具      —— 任务模型 / 打卡模型 / 调色板 / 时长格式化
//   【二】AppStore        —— 全局数据仓库（任务·打卡·统计，JSON 持久化）
//   【三】NotificationService —— 后台提醒（本地通知 / 精确闹钟）
//   【四】HomeShell       —— 主壳：底部导航 + 四个页面切换
//   【五】PomodoroPage    —— 计时页（核心状态机，绑定当前任务）
//   【六】TasksPage       —— 任务页（增删改 / 一键启用）
//   【七】CheckInPage     —— 自律打卡页
//   【八】StatsPage       —— 时间统计页（扇形图）
//   【九】共用组件与入口   —— 分段控件/进度环/控制按钮 + main()
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
// 前缀导入 Cupertino：只使用它的 Apple 风格弹窗，避免与 Material 同名类发生命名冲突
import 'package:flutter/cupertino.dart' as cui;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:vibration/vibration.dart';

// =============================================================================
// 【一】模型与工具
// =============================================================================

/// 三种计时模式
enum PomodoroMode { work, shortBreak, longBreak }

/// 模式扩展：中文名 / 默认时长 / 主题色 / 图标
extension PomodoroModeX on PomodoroMode {
  /// 模式中文名
  String get label => switch (this) {
        PomodoroMode.work => '工作',
        PomodoroMode.shortBreak => '短休息',
        PomodoroMode.longBreak => '长休息',
      };

  /// 默认时长（单位：分钟），仅作为"默认番茄钟"的出厂值
  int get defaultMinutes => switch (this) {
        PomodoroMode.work => 25,
        PomodoroMode.shortBreak => 5,
        PomodoroMode.longBreak => 15,
      };

  /// 模式主题色（取自 iOS 系统色板的近似色）
  Color get color => switch (this) {
        PomodoroMode.work => const Color(0xFFFF6B6B), // 珊瑚红
        PomodoroMode.shortBreak => const Color(0xFF34C759), // iOS 绿
        PomodoroMode.longBreak => const Color(0xFF5E5CE6), // iOS 靛蓝
      };

  /// 模式图标
  IconData get icon => switch (this) {
        PomodoroMode.work => Icons.work_rounded,
        PomodoroMode.shortBreak => Icons.local_cafe_rounded,
        PomodoroMode.longBreak => Icons.spa_rounded,
      };
}

/// iOS 风格的中性色 + 全局主色（绿色，与 App 图标呼应）
class AppColors {
  /// 主文字色（对应 iOS 的 label 色）
  static const Color label = Color(0xFF1C1C1E);

  /// 次要文字色（对应 iOS 的 secondaryLabel 色）
  static const Color secondaryLabel = Color(0xFF8E8E93);

  /// 全局主题绿（与 App 图标同色系）
  static const Color accent = Color(0xFF2FB65C);

  /// 页面浅灰背景（对应 iOS groupedBackground）
  static const Color pageBackground = Color(0xFFF5F5F7);
}

/// 单个任务：名称 + 该任务专属的番茄钟参数 + 计时方式（倒计时 / 正计时）
class TaskItem {
  const TaskItem({
    required this.id,
    required this.name,
    required this.workMinutes,
    required this.shortBreakMinutes,
    required this.longBreakMinutes,
    required this.colorIndex,
    this.countUp = false,
  });

  /// 任务唯一 ID（默认任务固定为 '0'）
  final String id;

  /// 任务名称
  final String name;

  /// 工作时长（分钟）——正计时任务不使用该值，但保留配置以便随时切回倒计时
  final int workMinutes;

  /// 短休息时长（分钟）——正计时任务不使用
  final int shortBreakMinutes;

  /// 长休息时长（分钟）——正计时任务不使用
  final int longBreakMinutes;

  /// 调色板序号（用于统计扇形图配色，稳定不随排序变化）
  final int colorIndex;

  /// 计时方式：false = 倒计时（番茄钟）；true = 正计时（自由计时，不限时长）
  final bool countUp;

  /// 取某个模式对应的时长（分钟）
  int minutesOf(PomodoroMode mode) => switch (mode) {
        PomodoroMode.work => workMinutes,
        PomodoroMode.shortBreak => shortBreakMinutes,
        PomodoroMode.longBreak => longBreakMinutes,
      };

  /// 复制并修改部分字段
  TaskItem copyWith({
    String? name,
    int? workMinutes,
    int? shortBreakMinutes,
    int? longBreakMinutes,
    bool? countUp,
  }) {
    return TaskItem(
      id: id,
      name: name ?? this.name,
      workMinutes: workMinutes ?? this.workMinutes,
      shortBreakMinutes: shortBreakMinutes ?? this.shortBreakMinutes,
      longBreakMinutes: longBreakMinutes ?? this.longBreakMinutes,
      colorIndex: colorIndex,
      countUp: countUp ?? this.countUp,
    );
  }

  /// 序列化为 JSON（本地存储用）
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'work': workMinutes,
        'short': shortBreakMinutes,
        'long': longBreakMinutes,
        'color': colorIndex,
        'countUp': countUp,
      };

  /// 从 JSON 反序列化（容错：缺字段时回退默认值；旧数据无 countUp 时视为倒计时）
  factory TaskItem.fromJson(Map<String, dynamic> m) => TaskItem(
        id: (m['id'] ?? '') as String,
        name: (m['name'] ?? '未命名任务') as String,
        workMinutes: ((m['work'] ?? 25) as num).toInt().clamp(1, 180),
        shortBreakMinutes: ((m['short'] ?? 5) as num).toInt().clamp(1, 180),
        longBreakMinutes: ((m['long'] ?? 15) as num).toInt().clamp(1, 180),
        colorIndex: ((m['color'] ?? 1) as num).toInt(),
        countUp: (m['countUp'] ?? false) as bool,
      );
}

/// 单个打卡项（例如：早起 / 跑步 / 读书）
class CheckInItem {
  const CheckInItem({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name};

  factory CheckInItem.fromJson(Map<String, dynamic> m) =>
      CheckInItem(id: (m['id'] ?? '') as String, name: (m['name'] ?? '打卡项') as String);
}

/// 任务调色板（iOS 系统色系，用于统计扇形图与任务标记）
const List<Color> kTaskPalette = <Color>[
  Color(0xFF2FB65C), // 绿
  Color(0xFF0A84FF), // 蓝
  Color(0xFFFF9F0A), // 橙
  Color(0xFFBF5AF2), // 紫
  Color(0xFFFF6B6B), // 红
  Color(0xFF5AC8FA), // 青
  Color(0xFF5E5CE6), // 靛
  Color(0xFFFFD60A), // 黄
  Color(0xFFFF375F), // 粉
  Color(0xFF30D158), // 亮绿
];

/// 按序号取调色板颜色（循环使用）
Color taskColor(int index) => kTaskPalette[index % kTaskPalette.length];

/// 秒数 → 中文时长文案："45秒" / "35分钟" / "1小时35分"
String formatDuration(int seconds) {
  if (seconds <= 0) return '0分钟';
  if (seconds < 60) return '$seconds秒';
  final int minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes分钟';
  final int hours = minutes ~/ 60;
  final int rest = minutes % 60;
  return rest == 0 ? '$hours小时' : '$hours小时$rest分';
}

/// DateTime → "yyyy-MM-dd" 键（打卡记录用）
String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 星期几中文（周一~周日）
String weekdayCn(DateTime d) => '周${const <String>['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1]}';

// =============================================================================
// 【二】AppStore —— 全局数据仓库（任务 / 打卡 / 统计）
// =============================================================================

/// 单例数据仓库：集中管理所有跨页面共享的数据，变化时通知界面刷新。
/// 持久化方案：全部 JSON 编码后存进 SharedPreferences（数据量小、无额外依赖）。
class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore instance = AppStore._();

  /// 默认任务（未选择任何任务时使用的"默认番茄钟"）
  static const String defaultTaskId = '0';
  static const String defaultTaskName = '默认番茄钟';

  // ---------- 本地存储键名 ----------
  static const String _kTasks = 'tasks_v1'; // 任务列表（JSON）
  static const String _kActiveTask = 'active_task_id'; // 当前启用任务 ID
  static const String _kTaskStats = 'task_stats_v1'; // 旧版：任务累计秒数（仅用于兼容迁移）
  static const String _kTaskDaily = 'task_daily_v1'; // 任务按天专注历史：{任务ID: {日期: 秒数}}
  static const String _kCheckItems = 'checkin_items_v1'; // 打卡项列表（JSON）
  static const String _kCheckRecords = 'checkin_records_v1'; // 打卡记录（JSON）
  static const String _kColorSeq = 'task_color_seq'; // 调色板序号自增计数

  late SharedPreferences prefs;
  bool _loaded = false;
  bool get loaded => _loaded;

  /// 任务列表（不含"默认番茄钟"）
  final List<TaskItem> tasks = <TaskItem>[];

  /// 打卡项列表
  final List<CheckInItem> checkinItems = <CheckInItem>[];

  /// 打卡记录：打卡项 ID → 已打卡的日期集合（"yyyy-MM-dd"）
  final Map<String, Set<String>> checkinRecords = <String, Set<String>>{};

  /// 任务专注时长历史：任务 ID → {日期(yyyy-MM-dd) → 秒数}（含默认任务 '0'）
  /// —— 按天存档是日/周/月统计的数据基础，全部保存在本地
  final Map<String, Map<String, int>> taskDaily = <String, Map<String, int>>{};

  /// 当前启用的任务 ID（'0' = 默认番茄钟）
  String activeTaskId = defaultTaskId;

  // ---------- 默认番茄钟时长（无任务时使用，沿用 v1 的存储键） ----------
  int defaultWorkMin = 25;
  int defaultShortMin = 5;
  int defaultLongMin = 15;

  /// 默认番茄钟的计时方式：false = 倒计时（番茄钟），true = 正计时（自由计时）
  bool defaultCountUp = false;

  /// 调色板自增序号（创建任务时递增，保证配色稳定）
  int _colorSeq = 1;

  // ===================== 读取 =====================

  /// 启动时读取全部本地数据（在 main() 里 await 一次）
  Future<void> load() async {
    if (_loaded) return;
    prefs = await SharedPreferences.getInstance();

    defaultWorkMin = prefs.getInt('work_minutes') ?? 25;
    defaultShortMin = prefs.getInt('short_minutes') ?? 5;
    defaultLongMin = prefs.getInt('long_minutes') ?? 15;
    defaultCountUp = prefs.getBool('default_count_up') ?? false;

    // 任务列表
    final String? tasksRaw = prefs.getString(_kTasks);
    if (tasksRaw != null) {
      try {
        final List<dynamic> list = jsonDecode(tasksRaw) as List<dynamic>;
        tasks
          ..clear()
          ..addAll(list.map((dynamic e) => TaskItem.fromJson(e as Map<String, dynamic>)));
      } catch (_) {}
    }

    // 打卡项 + 打卡记录
    final String? itemsRaw = prefs.getString(_kCheckItems);
    if (itemsRaw != null) {
      try {
        final List<dynamic> list = jsonDecode(itemsRaw) as List<dynamic>;
        checkinItems
          ..clear()
          ..addAll(list.map((dynamic e) => CheckInItem.fromJson(e as Map<String, dynamic>)));
      } catch (_) {}
    }
    final String? recordsRaw = prefs.getString(_kCheckRecords);
    if (recordsRaw != null) {
      try {
        final Map<String, dynamic> m = jsonDecode(recordsRaw) as Map<String, dynamic>;
        checkinRecords.clear();
        m.forEach((String k, dynamic v) {
          checkinRecords[k] = (v as List<dynamic>).map((dynamic e) => e as String).toSet();
        });
      } catch (_) {}
    }

    // 统计（按天历史）
    final String? dailyRaw = prefs.getString(_kTaskDaily);
    if (dailyRaw != null) {
      try {
        final Map<String, dynamic> m = jsonDecode(dailyRaw) as Map<String, dynamic>;
        taskDaily.clear();
        m.forEach((String taskId, dynamic days) {
          final Map<String, dynamic> dm = days as Map<String, dynamic>;
          taskDaily[taskId] = <String, int>{
            for (final MapEntry<String, dynamic> e in dm.entries) e.key: (e.value as num).toInt(),
          };
        });
      } catch (_) {}
    } else {
      // 兼容迁移：v1.1 只有累计总时长、没有日期维度 —— 折入今天并换用新格式
      final String? statsRaw = prefs.getString(_kTaskStats);
      if (statsRaw != null) {
        try {
          final Map<String, dynamic> m = jsonDecode(statsRaw) as Map<String, dynamic>;
          final String today = dateKey(DateTime.now());
          m.forEach((String k, dynamic v) {
            final int sec = (v as num).toInt();
            if (sec > 0) taskDaily[k] = <String, int>{today: sec};
          });
          await prefs.remove(_kTaskStats);
        } catch (_) {}
      }
    }

    // 当前任务
    activeTaskId = prefs.getString(_kActiveTask) ?? defaultTaskId;
    if (activeTaskId != defaultTaskId && taskById(activeTaskId) == null) {
      activeTaskId = defaultTaskId;
    }
    _colorSeq = prefs.getInt(_kColorSeq) ?? (tasks.length + 1);
    _loaded = true;
  }

  // ===================== 便捷查询 =====================

  /// 按 ID 查任务（找不到返回 null）
  TaskItem? taskById(String id) {
    for (final TaskItem t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 当前任务显示名
  String get activeTaskName =>
      activeTaskId == defaultTaskId ? defaultTaskName : (taskById(activeTaskId)?.name ?? defaultTaskName);

  /// 当前任务在某模式下的时长（分钟）—— 计时页取时长的唯一入口
  int minutesOf(PomodoroMode mode) {
    if (activeTaskId == defaultTaskId) {
      return switch (mode) {
        PomodoroMode.work => defaultWorkMin,
        PomodoroMode.shortBreak => defaultShortMin,
        PomodoroMode.longBreak => defaultLongMin,
      };
    }
    final TaskItem? t = taskById(activeTaskId);
    return t?.minutesOf(mode) ?? mode.defaultMinutes;
  }

  /// 当前任务配置的计时方式：true = 正计时（自由计时）
  bool get activeTaskCountUp {
    if (activeTaskId == defaultTaskId) return defaultCountUp;
    return taskById(activeTaskId)?.countUp ?? false;
  }

  /// 打卡项今天是否已打勾
  bool isChecked(String itemId, String day) => checkinRecords[itemId]?.contains(day) ?? false;

  /// 连续打卡天数（从今天或昨天往前连续计算）
  int streakOf(String itemId) {
    final Set<String> set = checkinRecords[itemId] ?? const <String>{};
    if (set.isEmpty) return 0;
    DateTime day = DateTime.now();
    if (!set.contains(dateKey(day))) {
      day = day.subtract(const Duration(days: 1));
      if (!set.contains(dateKey(day))) return 0;
    }
    int streak = 0;
    while (set.contains(dateKey(day))) {
      streak += 1;
      day = day.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// 最近 7 天打卡情况（旧 → 新，最后一个是今天）
  List<bool> last7Days(String itemId) {
    final Set<String> set = checkinRecords[itemId] ?? const <String>{};
    final DateTime now = DateTime.now();
    return List<bool>.generate(7, (int i) => set.contains(dateKey(now.subtract(Duration(days: 6 - i)))));
  }

  // ===================== 任务 CRUD =====================

  /// 新建任务（返回创建好的任务对象）
  /// [countUp] = true 表示该任务默认使用「正计时（自由计时）」
  Future<TaskItem> addTask(String name, int work, int shortBreak, int longBreak, {bool countUp = false}) async {
    final TaskItem t = TaskItem(
      id: 't${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      workMinutes: work,
      shortBreakMinutes: shortBreak,
      longBreakMinutes: longBreak,
      colorIndex: _colorSeq++,
      countUp: countUp,
    );
    tasks.add(t);
    await prefs.setInt(_kColorSeq, _colorSeq);
    await _saveTasks();
    notifyListeners();
    return t;
  }

  /// 更新任务（编辑名称或时长）
  Future<void> updateTask(TaskItem updated) async {
    final int i = tasks.indexWhere((TaskItem t) => t.id == updated.id);
    if (i < 0) return;
    tasks[i] = updated;
    await _saveTasks();
    notifyListeners();
  }

  /// 删除任务（连同它的计时统计一起删除；若删除的是当前任务则回退到默认任务）
  Future<void> deleteTask(String id) async {
    tasks.removeWhere((TaskItem t) => t.id == id);
    taskDaily.remove(id); // 连同该任务的历史统计一起删除
    if (activeTaskId == id) {
      activeTaskId = defaultTaskId;
      await prefs.setString(_kActiveTask, activeTaskId);
    }
    await _saveTasks();
    await _saveDaily();
    notifyListeners();
  }

  /// 启用某个任务（'0' = 默认番茄钟）
  Future<void> setActiveTask(String id) async {
    activeTaskId = id;
    await prefs.setString(_kActiveTask, id);
    notifyListeners();
  }

  /// 修改"当前任务"的时长（默认任务 → 改全局默认值；普通任务 → 改该任务配置）
  Future<void> setActiveDurations({required int work, required int shortBreak, required int longBreak}) async {
    if (activeTaskId == defaultTaskId) {
      defaultWorkMin = work;
      defaultShortMin = shortBreak;
      defaultLongMin = longBreak;
      await prefs.setInt('work_minutes', work);
      await prefs.setInt('short_minutes', shortBreak);
      await prefs.setInt('long_minutes', longBreak);
      notifyListeners();
    } else {
      final TaskItem? t = taskById(activeTaskId);
      if (t != null) {
        await updateTask(t.copyWith(workMinutes: work, shortBreakMinutes: shortBreak, longBreakMinutes: longBreak));
      }
    }
  }

  /// 修改"当前任务"的计时方式（倒计时 / 正计时）
  Future<void> setActiveCountUp(bool countUp) async {
    if (activeTaskId == defaultTaskId) {
      defaultCountUp = countUp;
      await prefs.setBool('default_count_up', countUp);
      notifyListeners();
    } else {
      final TaskItem? t = taskById(activeTaskId);
      if (t != null) {
        await updateTask(t.copyWith(countUp: countUp));
      }
    }
  }

  // ===================== 统计 =====================

  /// 给某个任务累计专注秒数（计入今天这一天；完成一段工作 / 中途重置时调用）
  Future<void> addWorkSeconds(String taskId, int seconds) async {
    if (seconds <= 0) return;
    final String today = dateKey(DateTime.now());
    final Map<String, int> days = taskDaily.putIfAbsent(taskId, () => <String, int>{});
    days[today] = (days[today] ?? 0) + seconds;
    await _saveDaily();
    notifyListeners();
  }

  /// 某任务在 [start, end]（按日期、含端点）区间内的专注秒数 —— 日/周/月统计都走这里
  int secondsInRange(String taskId, DateTime start, DateTime end) {
    final Map<String, int>? days = taskDaily[taskId];
    if (days == null || days.isEmpty) return 0;
    final DateTime s = DateTime(start.year, start.month, start.day);
    final DateTime e = DateTime(end.year, end.month, end.day);
    int sum = 0;
    days.forEach((String day, int sec) {
      final DateTime d = DateTime.tryParse(day) ?? DateTime(2000);
      if (!d.isBefore(s) && !d.isAfter(e)) sum += sec;
    });
    return sum;
  }

  /// 某任务的全部历史专注秒数（所有日期之和）
  int allTimeFor(String taskId) {
    final Map<String, int>? days = taskDaily[taskId];
    if (days == null) return 0;
    return days.values.fold(0, (int a, int b) => a + b);
  }

  /// 全部任务的累计时长之和（秒）
  int get totalTrackedSeconds =>
      taskDaily.keys.fold(0, (int a, String id) => a + allTimeFor(id));

  // ===================== 打卡 =====================

  /// 新增打卡项
  Future<void> addCheckInItem(String name) async {
    checkinItems.add(CheckInItem(id: 'c${DateTime.now().millisecondsSinceEpoch}', name: name));
    await _saveCheckins();
    notifyListeners();
  }

  /// 删除打卡项（连同历史记录）
  Future<void> deleteCheckInItem(String id) async {
    checkinItems.removeWhere((CheckInItem e) => e.id == id);
    checkinRecords.remove(id);
    await _saveCheckins();
    notifyListeners();
  }

  /// 切换某个打卡项在某天的打卡状态
  Future<void> toggleCheckIn(String itemId, String day) async {
    final Set<String> set = checkinRecords.putIfAbsent(itemId, () => <String>{});
    if (!set.remove(day)) set.add(day);
    await _saveCheckins();
    notifyListeners();
  }

  // ===================== 持久化（内部） =====================

  Future<void> _saveTasks() async =>
      prefs.setString(_kTasks, jsonEncode(tasks.map((TaskItem t) => t.toJson()).toList()));

  Future<void> _saveDaily() async => prefs.setString(_kTaskDaily, jsonEncode(taskDaily));

  Future<void> _saveCheckins() async {
    await prefs.setString(_kCheckItems, jsonEncode(checkinItems.map((CheckInItem e) => e.toJson()).toList()));
    await prefs.setString(
      _kCheckRecords,
      jsonEncode(checkinRecords.map((String k, Set<String> v) => MapEntry<String, List<String>>(k, v.toList()))),
    );
  }
}

// =============================================================================
// 【三】NotificationService —— 后台提醒服务（与 v1 相同，仅换通知图标）
// =============================================================================

/// 封装 flutter_local_notifications 的单例服务。
///
/// 后台计时的实现原理：
///   · 计时本身基于"结束时间戳"（绝对时刻）推进，与页面是否可见无关；
///   · App 退到后台时，向系统注册一个"精确闹钟 + 本地通知"（时间 = 到点时刻），
///     到点由 Android 系统准时弹出通知（自带铃声 + 震动）；
///   · 即使 App 进程被系统回收，闹钟依然由系统保持，提醒不会丢失；
///   · 回到前台后撤销该通知，改由 App 内自己的震动 + 铃声提醒，避免双重打扰。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  /// 通知 ID：计时结束通知固定用同一个 ID，便于"覆盖调度 / 取消"
  static const int _timerNotificationId = 1001;

  /// 通知渠道（Android 8.0+ 必须）：渠道在第一次通知时自动创建
  static const String _channelId = 'pomodoro_timer_channel';
  static const String _channelName = '自力提醒';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// 初始化插件（在 main() 中调用一次）
  Future<void> init() async {
    if (_initialized) return;
    // 通知调度需要时区数据库。本项目统一用 UTC 表达"绝对时刻"，
    // 天然规避设备时区 / 夏令时带来的偏移问题
    tzdata.initializeTimeZones();
    // 通知小图标：使用 res/drawable 里的专用白色剪影图标（ic_stat_notify）
    const AndroidInitializationSettings android = AndroidInitializationSettings('ic_stat_notify');
    const InitializationSettings settings = InitializationSettings(android: android);
    // 注意：flutter_local_notifications v22 起 initialize 使用命名参数
    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  /// 申请"通知"运行时权限（Android 13+ 必须由用户授权才能弹出通知）。
  ///
  /// 关于精确闹钟权限（Android 12+ 的"闹钟与提醒"）：
  ///   本项目的 AndroidManifest 里声明了 USE_EXACT_ALARM，安装后自动授予，无需运行时申请；
  ///   若改为只声明 SCHEDULE_EXACT_ALARM（上架 Google Play 的合规做法），
  ///   可在此处再调用 android.requestExactAlarmsPermission() 引导用户手动开启。
  Future<void> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    try {
      await android.requestNotificationsPermission();
    } catch (_) {
      // 忽略：部分旧系统没有该 API
    }
  }

  /// 注册一条"计时结束"通知，在 [endTime] 时刻触发（用于后台计时提醒）
  Future<void> scheduleTimerEnd(
    DateTime endTime, {
    required String title,
    required String body,
  }) async {
    // 已经过期的时间点无需调度（边界保护）
    if (endTime.isBefore(DateTime.now())) return;
    try {
      await init();

      // 通知详情：最高重要性（弹出横幅）+ 铃声 + 震动
      final NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '自力 · 计时结束时提醒',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true, // 播放系统默认通知声音（渠道声音在首次创建时生效）
          enableVibration: true, // 通知自带震动
          category: AndroidNotificationCategory.alarm, // 归类为"闹钟"，降低被静音的几率
          visibility: NotificationVisibility.public, // 锁屏上可见
          ticker: '自力计时结束',
        ),
      );

      // 先查询是否可以精确调度（没有"闹钟与提醒"权限的 Android 12+ 设备会返回 false）
      AndroidScheduleMode mode = AndroidScheduleMode.exactAllowWhileIdle;
      try {
        final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        final bool canExact = await android?.canScheduleExactNotifications() ?? false;
        if (!canExact) mode = AndroidScheduleMode.inexactAllowWhileIdle;
      } catch (_) {
        // 查询失败就按精确模式尝试，外层有兜底
      }

      // tz.TZDateTime.from(x, tz.UTC)：把本地时间表达的"绝对时刻"转换成 UTC 下的同一时刻，
      // 交给系统调度时不会受设备时区影响
      final tz.TZDateTime when = tz.TZDateTime.from(endTime, tz.UTC);
      try {
        await _plugin.zonedSchedule(
          id: _timerNotificationId,
          title: title,
          body: body,
          scheduledDate: when,
          notificationDetails: details,
          androidScheduleMode: mode,
        );
      } catch (_) {
        // 精确调度被系统拒绝时的兜底：允许休眠的粗略调度（仍会触发，可能略有延迟）
        await _plugin.zonedSchedule(
          id: _timerNotificationId,
          title: title,
          body: body,
          scheduledDate: when,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    } catch (_) {
      // 无通知能力时静默失败：前台提醒功能不受影响
    }
  }

  /// 取消尚未触发的"计时结束"通知（暂停 / 重置 / 回到前台接管时调用）
  Future<void> cancelTimerEnd() async {
    try {
      await _plugin.cancel(id: _timerNotificationId);
    } catch (_) {
      // 忽略取消失败
    }
  }
}

// =============================================================================
// 【四】HomeShell —— 主壳：底部导航（像微信一样切换四个模块）
// =============================================================================

/// 底部导航壳：计时 / 任务 / 打卡 / 统计，四个页面用 IndexedStack 常驻内存
/// （这样切到别的页面时，计时器依然在后台继续走，回来不会重置）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _switchTo(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBackground,
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          PomodoroPage(onOpenTasks: () => _switchTo(1)),
          TasksPage(onOpenTimer: () => _switchTo(0)),
          const CheckInPage(),
          const StatsPage(),
        ],
      ),
      // 底部导航栏（白色 + 顶部细分线，选中项绿色高亮）
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.black.withValues(alpha: 0.06), width: 0.8)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 54,
            child: Row(
              children: <Widget>[
                _navItem(0, Icons.timer_outlined, '计时'),
                _navItem(1, Icons.checklist_rounded, '任务'),
                _navItem(2, Icons.task_alt, '打卡'),
                _navItem(3, Icons.pie_chart_outline, '统计'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 单个导航项
  Widget _navItem(int i, IconData icon, String label) {
    final bool selected = _index == i;
    final Color color = selected ? AppColors.accent : AppColors.secondaryLabel;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _switchTo(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 【五】PomodoroPage —— 计时页
// =============================================================================

/// 计时页：承载全部计时状态（计时 / 计数 / 持久化 / 前后台补偿），
/// 并绑定「当前任务」——不同任务沿用各自的番茄钟参数。
class PomodoroPage extends StatefulWidget {
  const PomodoroPage({super.key, this.onOpenTasks});

  /// 点击"管理任务"时跳转到任务页的回调
  final VoidCallback? onOpenTasks;

  @override
  State<PomodoroPage> createState() => _PomodoroPageState();
}

class _PomodoroPageState extends State<PomodoroPage> with WidgetsBindingObserver {
  // ---------- 本地存储的键名（计时器自身状态） ----------
  static const String _kCompletedCount = 'completed_pomodoros'; // 累计完成的番茄数
  static const String _kMode = 'saved_mode'; // 上次所在的倒计时模式
  static const String _kCountUp = 'saved_count_up'; // 上次是否为正计时
  static const String _kRunning = 'saved_running'; // 上次退出时是否运行中
  static const String _kSegmentStart = 'saved_segment_start_ms'; // 当前运行片段的起点（毫秒时间戳）
  static const String _kElapsedBase = 'saved_elapsed_base_ms'; // 已累计的专注毫秒（不含当前片段）
  static const String _kPermissionAsked = 'permission_asked'; // 是否已申请过系统权限

  // ---------- 基础设施 ----------
  SharedPreferences? _prefs; // 本地存储（由 AppStore 提供）
  final AudioPlayer _player = AudioPlayer(); // 提示音播放器（复用同一个实例）

  // ---------- 运行时状态 ----------
  bool _loading = true; // 首次进入时先读取本地数据，避免画面闪烁
  PomodoroMode _mode = PomodoroMode.work; // 当前倒计时模式
  bool _countUp = false; // 是否处于「正计时」（自由计时）模式
  bool _isRunning = false; // 是否正在计时
  DateTime? _segmentStart; // 当前运行片段的起点（绝对时间 —— 后台/重启后依然准确）
  int _elapsedBaseMs = 0; // 已累计的专注毫秒（暂停之前的部分）
  int _completedCount = 0; // 累计完成的番茄数
  Timer? _ticker; // UI 刷新定时器（每 250ms）
  String? _pendingNotice; // 待展示的一次性提示（补结算等场景）

  /// 当前这段"专注时间"记在哪个任务名下（在开始计时那一刻绑定，防止中途切任务记错账）
  String _sessionTaskId = AppStore.defaultTaskId;

  /// 跟踪「当前任务 + 其计时方式设置」的变化（用于自动同步倒计时 / 正计时）
  String _lastTaskId = '';
  bool _lastCountUpSetting = false;

  // ====================== 生命周期 ======================

  @override
  void initState() {
    super.initState();
    // 监听前后台切换：这是"后台计时"的补偿入口
    WidgetsBinding.instance.addObserver(this);
    // 监听全局数据变化（任务切换 / 编辑后同步刷新界面）
    AppStore.instance.addListener(_onStoreChanged);
    _sessionTaskId = AppStore.instance.activeTaskId;
    _loadState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppStore.instance.removeListener(_onStoreChanged);
    _ticker?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// 数据仓库变化回调：剩余时长由「总时长 - 已用时长」实时推导，这里只需要刷新界面；
  /// 空闲时如果切了任务，显示也会自动跟随（不会再残留旧任务的剩余时间）。
  /// 另外负责把「任务配置的计时方式」（倒计时 / 正计时）同步到计时器。
  void _onStoreChanged() {
    if (!mounted) return;
    _syncModeWithActiveTask();
    setState(() {});
  }

  /// 把当前任务配置的计时方式同步到计时器：
  ///   · 任务被切换（含从任务页点启用）→ 先给进行中的会话记账并重置，再采用新任务的计时方式；
  ///   · 仅计时方式设置被修改（任务编辑弹窗里切换）→ 空闲时才生效，避免打断进行中的会话。
  void _syncModeWithActiveTask() {
    final AppStore store = AppStore.instance;
    final String id = store.activeTaskId;
    final bool want = store.activeTaskCountUp;
    final bool taskChanged = id != _lastTaskId;
    final bool settingChanged = want != _lastCountUpSetting;
    if (!taskChanged && !settingChanged) return;
    _lastTaskId = id;
    _lastCountUpSetting = want;

    if (taskChanged) {
      // 任务换了：把旧任务的会话时间先记账（按 _sessionTaskId），然后干净重来
      if (_isRunning || _elapsedMs > 0) {
        _commitAndClearSession().then((_) {});
        _ticker?.cancel();
        _ticker = null;
        _isRunning = false;
        _segmentStart = null;
        _elapsedBaseMs = 0;
        NotificationService.instance.cancelTimerEnd();
      }
      _countUp = want;
      _saveState();
      return;
    }

    // 只是改了计时方式设置
    if (_isRunning || _elapsedMs > 0) return; // 非空闲：不打断当前会话
    if (want == _countUp) return;
    _countUp = want;
    _ticker?.cancel();
    _ticker = null;
    _segmentStart = null;
    _elapsedBaseMs = 0;
    NotificationService.instance.cancelTimerEnd();
    _saveState();
  }

  /// App 前后台切换回调
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // 进入后台：若正在倒计时，给系统排一个"到点闹钟通知"
      _scheduleBackgroundAlert();
    } else if (state == AppLifecycleState.resumed) {
      // 回到前台：接管计时并校验是否已经到点
      _handleResume();
    }
  }

  // ====================== 派生状态（全部由"已用时长"实时推导） ======================

  /// 已用时长（毫秒）＝ 累计基数 + 当前运行片段（这是统计记账的唯一事实来源）
  int get _elapsedMs {
    final DateTime? seg = _segmentStart;
    if (_isRunning && seg != null) {
      return _elapsedBaseMs + DateTime.now().difference(seg).inMilliseconds;
    }
    return _elapsedBaseMs;
  }

  /// 当前任务、当前模式下的总毫秒数（仅倒计时使用）
  int _totalMs([PomodoroMode? mode]) => AppStore.instance.minutesOf(mode ?? _mode) * 60 * 1000;

  /// 剩余时长（倒计时用；实际用时超过总时长时收敛为 0，绝不为负）
  int get _remainingMs {
    final int r = _totalMs() - _elapsedMs;
    return r < 0 ? 0 : r;
  }

  /// App 当前是否在前台
  bool get _inForeground =>
      (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed;

  /// 当前主题色（正计时用品牌绿；倒计时跟随模式色）
  Color get _themeColor => _countUp ? AppColors.accent : _mode.color;

  /// 屏幕显示的总秒数：倒计时 = 剩余（向上取整）；正计时 = 已用（向下取整）
  int get _displaySeconds =>
      _countUp ? (_elapsedMs ~/ 1000) : ((_remainingMs + 999) ~/ 1000);

  /// 圆环进度：倒计时 = 剩余比例；正计时 = 本小时的进度（走满一圈 = 专注 1 小时）
  double get _progress {
    if (_countUp) {
      return (_elapsedMs / 3600000).clamp(0.0, 1.0).toDouble();
    }
    final int total = _totalMs();
    if (total <= 0) return 0;
    return (_remainingMs / total).clamp(0.0, 1.0).toDouble();
  }

  /// 时间文本，例如 24:59 / 00:15
  String get _timeText {
    final int s = _displaySeconds;
    final String m = (s ~/ 60).toString().padLeft(2, '0');
    final String sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  /// 状态描述文案
  String get _statusText {
    if (_countUp) {
      if (_isRunning) return '自由计时中';
      if (_elapsedMs > 0) return '已暂停';
      return '准备开始';
    }
    if (_isRunning) return _mode == PomodoroMode.work ? '专注中' : '休息中';
    if (_elapsedMs > 0) return '已暂停';
    return '准备开始';
  }

  /// 时间下方的小字说明
  String get _subText {
    if (_countUp) return '自由计时 · 圆环走满=1 小时';
    if (_mode == PomodoroMode.work) return '第 ${_completedCount + 1} 个番茄';
    if (_mode == PomodoroMode.longBreak) return '长休息 · 好好放松';
    return '短休息 · 喝口水吧';
  }

  /// 本轮进度（0~4）：每 4 个番茄进入一次长休息
  int get _cycleDone {
    if (_mode == PomodoroMode.longBreak && _completedCount > 0 && _completedCount % 4 == 0) {
      return 4;
    }
    return _completedCount % 4;
  }

  // ====================== 核心操作 ======================

  /// 开始 / 继续计时（倒计时与正计时共用）
  Future<void> _start() async {
    if (_isRunning) return; // 防重复点击

    // 首次开始前申请通知 / 精确闹钟权限（只申请一次）
    await _maybeRequestPermissions();

    // 如果这是一个全新的会话（已用为 0），在此刻绑定当前任务
    if (_elapsedBaseMs == 0 && _segmentStart == null) {
      _sessionTaskId = AppStore.instance.activeTaskId;
    }
    _segmentStart = DateTime.now();
    _isRunning = true;
    _startTicker();
    await _saveState();
    if (mounted) setState(() {});
  }

  /// 暂停：把当前运行片段折算进累计基数（暂停/恢复不掉秒）
  Future<void> _pause() async {
    if (!_isRunning) return;
    final DateTime? seg = _segmentStart;
    if (seg != null) {
      _elapsedBaseMs += math.max(0, DateTime.now().difference(seg).inMilliseconds);
    }
    _segmentStart = null;
    _isRunning = false;
    _ticker?.cancel();
    _ticker = null;
    await NotificationService.instance.cancelTimerEnd(); // 已暂停，不再需要后台闹钟
    await _saveState();
    if (mounted) setState(() {});
  }

  /// 结束当前会话段：把【实际已用时间】记入统计并从 0 重新起算。
  /// 运行中调用时会无缝续跑（片段起点重置为此刻）；统计一律按秒表累计的真实用时记账。
  Future<void> _commitAndClearSession() async {
    final int elapsed = _elapsedMs;
    final bool credit = _countUp || _mode == PomodoroMode.work; // 休息时段不记账
    if (credit && elapsed >= 1000) {
      await AppStore.instance.addWorkSeconds(_sessionTaskId, (elapsed / 1000).round());
    }
    _elapsedBaseMs = 0;
    _segmentStart = _isRunning ? DateTime.now() : null;
    _sessionTaskId = AppStore.instance.activeTaskId;
  }

  /// 重置：停止计时，把已用时间记入统计，回到完整时长（不清空累计数据）
  Future<void> _reset() async {
    await _commitAndClearSession(); // 中途重置：已专注的时间照样记入统计
    _ticker?.cancel();
    _ticker = null;
    _isRunning = false;
    _segmentStart = null;
    await NotificationService.instance.cancelTimerEnd();
    await _saveState();
    if (mounted) setState(() {});
  }

  /// 跳过当前时段，直接进入下一时段（重载：正计时下 = 结束并记录）
  Future<void> _skip() async {
    if (_countUp) {
      await _finishCountUp();
      return;
    }
    await _completeSession(skip: true);
  }

  /// 【正计时】结束本次自由计时：记录实际用时并归零（保持正计时模式）
  Future<void> _finishCountUp() async {
    final int elapsed = _elapsedMs;
    _ticker?.cancel();
    _ticker = null;
    _isRunning = false;
    _elapsedBaseMs = 0;
    _segmentStart = null;
    await NotificationService.instance.cancelTimerEnd();
    if (elapsed >= 1000) {
      final int secs = (elapsed / 1000).round();
      await AppStore.instance.addWorkSeconds(_sessionTaskId, secs);
      _pendingNotice = '已记录自由计时 ${formatDuration(secs)}';
    }
    _sessionTaskId = AppStore.instance.activeTaskId;
    await _saveState();
    if (mounted) setState(() {});
    _flushPendingNotice();
  }

  /// 切换到某个倒计时模式（仅在未运行时）
  Future<void> _switchMode(PomodoroMode mode) async {
    if (_isRunning || (_mode == mode && !_countUp)) return;
    await _commitAndClearSession(); // 先把已用的时间记账（若在正计时里切换，同样先入账）
    setState(() {
      _mode = mode;
      _countUp = false;
      _segmentStart = null;
      _elapsedBaseMs = 0;
    });
    await NotificationService.instance.cancelTimerEnd();
    await _saveState();
  }

  /// 切换到「正计时 / 自由计时」（不限时长，正着数，结束/重置时按实际用时记账）
  Future<void> _switchToCountUp() async {
    if (_isRunning || _countUp) return;
    await _commitAndClearSession();
    setState(() {
      _countUp = true;
      _segmentStart = null;
      _elapsedBaseMs = 0;
    });
    await NotificationService.instance.cancelTimerEnd();
    await _saveState();
  }

  /// 切换当前任务：先给"这次会话所属的任务"结算已用时间，再切换到新任务
  Future<void> _applyTask(String taskId) async {
    final AppStore store = AppStore.instance;
    if (taskId == store.activeTaskId) return;
    await _commitAndClearSession();
    await store.setActiveTask(taskId);
    if (!mounted) return;
    setState(() {
      _ticker?.cancel();
      _ticker = null;
      _isRunning = false;
      _segmentStart = null;
      _elapsedBaseMs = 0;
    });
    await NotificationService.instance.cancelTimerEnd();
    await _saveState();
  }

  // ====================== 计时与结算 ======================

  /// 启动 UI 刷新定时器（每 250ms 刷新一次数字与圆环）
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_isRunning) return;
      if (!_countUp && _remainingMs <= 0) {
        // 倒计时到点：结算
        _completeSession();
      } else if (mounted) {
        setState(() {}); // 刷新 UI
      }
    });
  }

  /// 结算一个（倒计时）时段：
  ///   · 记账规则：无论"完成"还是"跳过/中断"，一律按【实际用时】计入统计（休息时段不计）；
  ///   · [skip] = true  ：用户主动跳过，不计番茄数；
  ///   · 前台完成：撤销后台通知，震动 + 铃声 + 弹窗；
  ///   · 后台完成：只切换状态并记一条待提示消息（提醒由系统通知负责）；
  ///   · silent 补结算：App 重启后发现计时已在后台到点，静默补记账。
  Future<void> _completeSession({bool skip = false, bool silent = false}) async {
    if (_countUp) {
      // 正计时不会"到点"，保险起见按手动结束处理
      await _finishCountUp();
      return;
    }
    final PomodoroMode finished = _mode;
    final int elapsed = _elapsedMs;

    _ticker?.cancel();
    _ticker = null;
    _isRunning = false;
    _segmentStart = null;
    _elapsedBaseMs = 0;

    // 实际用时记入统计（完成 / 跳过都按真实用时，杜绝"虚拟时长"）
    if (finished == PomodoroMode.work && elapsed >= 1000) {
      await AppStore.instance.addWorkSeconds(_sessionTaskId, (elapsed / 1000).round());
    }
    _sessionTaskId = AppStore.instance.activeTaskId;

    // 只有完整完成"工作"时段才计为一个番茄（跳过的不算）
    if (!skip && finished == PomodoroMode.work) _completedCount += 1;

    // 切换到下一时段：工作 → 休息（每 4 个番茄一次长休息）；休息 → 工作
    final PomodoroMode next = _nextMode(finished);
    _mode = next;

    if (!skip && !silent && _inForeground) {
      // 前台完成：撤销后台通知（避免双重提醒），用应用内的铃声 + 震动提醒
      await NotificationService.instance.cancelTimerEnd();
      await _alert();
    } else if (!skip) {
      // 后台完成 / 重启补结算：留一条提示，等回到前台再显示
      _pendingNotice = '「${finished.label}」已结束，已自动切换到${next.label}';
    }

    await _saveState();
    if (!mounted) return;
    setState(() {});
    if (!skip && !silent && _inForeground) _showFinishedDialog(finished);
    _flushPendingNotice();
  }

  /// 下一时段规则：
  ///   工作结束 → 距下一次长休息已满 4 个番茄则长休息，否则短休息；
  ///   任何休息结束 → 工作。
  PomodoroMode _nextMode(PomodoroMode finished) {
    if (finished != PomodoroMode.work) return PomodoroMode.work;
    return (_completedCount > 0 && _completedCount % 4 == 0)
        ? PomodoroMode.longBreak
        : PomodoroMode.shortBreak;
  }

  /// 到点提醒：震动（三段式）+ 提示音
  Future<void> _alert() async {
    // 1) 震动：震 0.6s → 停 0.25s → 震 0.6s → 停 0.25s → 震 0.9s
    try {
      final bool hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator) {
        Vibration.vibrate(pattern: <int>[0, 600, 250, 600, 250, 900]);
      }
    } catch (_) {
      // 无马达或权限异常时忽略
    }
    // 2) 提示音：播放内置铃声 assets/sounds/ding.wav
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/ding.wav'), volume: 0.9);
    } catch (_) {
      // 播放失败不影响其它提醒方式
    }
  }

  /// 时段结束的弹窗（Apple 风格的 CupertinoAlertDialog）
  Future<void> _showFinishedDialog(PomodoroMode finished) async {
    if (!mounted) return;
    final PomodoroMode next = _mode;
    final bool isWork = finished == PomodoroMode.work;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => cui.CupertinoAlertDialog(
        title: Text(isWork ? '🎉 工作完成' : '☕️ 休息结束'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            isWork
                ? '已完成 $_completedCount 个番茄，接下来是${next.label}。'
                : '充电完毕，开始下一个番茄吧！',
          ),
        ),
        actions: <Widget>[
          cui.CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          cui.CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              Navigator.of(ctx).pop();
              _start();
            },
            child: Text('开始${next.label}'),
          ),
        ],
      ),
    );
  }

  // ====================== 前后台补偿 ======================

  /// 通知文案（按模式区分）
  (String, String) _notificationText(PomodoroMode mode) => switch (mode) {
        PomodoroMode.work => ('⏰ 工作时间到！', '完成一个番茄，休息一下吧'),
        PomodoroMode.shortBreak => ('☕️ 短休息结束', '继续下一个番茄吧'),
        PomodoroMode.longBreak => ('🌿 长休息结束', '开始新的一轮吧'),
      };

  /// 进入后台时：为运行中的【倒计时】注册系统闹钟通知（正计时没有"到点"，无需闹钟）
  void _scheduleBackgroundAlert() {
    if (!_isRunning || _countUp) return;
    final int remain = _remainingMs;
    if (remain <= 0) return;
    final DateTime end = DateTime.now().add(Duration(milliseconds: remain));
    final (String title, String body) = _notificationText(_mode);
    unawaited(NotificationService.instance.scheduleTimerEnd(end, title: title, body: body));
  }

  /// 回到前台时：
  ///   1. 撤销后台闹钟（前台由 App 自己提醒，避免重复）；
  ///   2. 若倒计时在后台期间已经到点（且定时器没来得及结算），静默补结算。
  Future<void> _handleResume() async {
    await NotificationService.instance.cancelTimerEnd();
    if (!_countUp && _isRunning && _remainingMs <= 0) {
      // 到点提醒此前已由系统通知完成，这里静默结算即可
      await _completeSession(silent: true);
    }
    _flushPendingNotice();
  }

  // ====================== 持久化 ======================

  /// 保存计时器状态到本地
  Future<void> _saveState() async {
    final SharedPreferences? p = _prefs;
    if (p == null) return;
    await p.setInt(_kCompletedCount, _completedCount);
    await p.setInt(_kMode, _mode.index);
    await p.setBool(_kCountUp, _countUp);
    await p.setBool(_kRunning, _isRunning);
    await p.setInt(_kSegmentStart, _segmentStart?.millisecondsSinceEpoch ?? 0);
    await p.setInt(_kElapsedBase, _elapsedBaseMs);
  }

  /// 读取本地状态并恢复现场（重启 App / 进程被杀后进入此流程）
  Future<void> _loadState() async {
    final AppStore store = AppStore.instance;
    final SharedPreferences p = store.prefs;
    _prefs = p;

    _completedCount = p.getInt(_kCompletedCount) ?? 0;
    final int modeIndex = (p.getInt(_kMode) ?? 0).clamp(0, PomodoroMode.values.length - 1).toInt();
    _mode = PomodoroMode.values[modeIndex];
    _countUp = p.getBool(_kCountUp) ?? false;
    _elapsedBaseMs = math.max(0, p.getInt(_kElapsedBase) ?? 0);

    final bool savedRunning = p.getBool(_kRunning) ?? false;
    final int segMs = p.getInt(_kSegmentStart) ?? 0;
    if (savedRunning && segMs > 0) {
      // 上次退出时正在计时 → 用绝对时间点恢复（与进程生死无关，时间继续走）
      _segmentStart = DateTime.fromMillisecondsSinceEpoch(segMs);
      _isRunning = true;
      _startTicker();
      if (!_countUp && _remainingMs <= 0) {
        // 倒计时已在 App 未运行期间到点 → 静默补结算（补记时长、切换模式）
        await _completeSession(silent: true);
      } else if (!_countUp) {
        // 进程重启会清掉之前的系统闹钟，这里按剩余时间补注册一次
        final DateTime end = DateTime.now().add(Duration(milliseconds: _remainingMs));
        final (String title, String body) = _notificationText(_mode);
        unawaited(NotificationService.instance.scheduleTimerEnd(end, title: title, body: body));
      }
    } else {
      // 未运行（空闲/暂停中）：收敛异常数据
      if (!_countUp) {
        final int total = _totalMs();
        if (_elapsedBaseMs > total) _elapsedBaseMs = total; // 倒计时的已用不应超过总时长
      }
      _isRunning = false;
      _segmentStart = null;
    }
    _sessionTaskId = store.activeTaskId;
    _lastTaskId = store.activeTaskId;
    _lastCountUpSetting = store.activeTaskCountUp;

    if (mounted) setState(() => _loading = false);
    _flushPendingNotice();
  }

  /// 首次开始计时前申请通知 / 闹钟权限（只申请一次）
  Future<void> _maybeRequestPermissions() async {
    final SharedPreferences? p = _prefs;
    if (p == null || (p.getBool(_kPermissionAsked) ?? false)) return;
    await p.setBool(_kPermissionAsked, true);
    await NotificationService.instance.requestPermissions();
  }

  /// 展示一次性提示（SnackBar）
  void _flushPendingNotice() {
    final String? msg = _pendingNotice;
    if (msg == null || !mounted) return;
    _pendingNotice = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
      );
    });
  }

  // ====================== 任务选择 & 自定义时长 ======================

  /// 弹出"选择任务"底部面板（Apple 风格 ActionSheet 替代）
  Future<void> _showTaskPicker() async {
    if (_isRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先暂停计时，再切换任务')),
      );
      return;
    }
    final AppStore store = AppStore.instance;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              const Text('选择任务',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.label)),
              const SizedBox(height: 4),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    _taskPickTile(
                      ctx,
                      store,
                      AppStore.defaultTaskId,
                      AppStore.defaultTaskName,
                      store.defaultCountUp
                          ? '正计时（自由计时）'
                          : '${store.defaultWorkMin} / ${store.defaultShortMin} / ${store.defaultLongMin} 分钟',
                      0,
                    ),
                    for (final TaskItem t in store.tasks)
                      _taskPickTile(
                        ctx,
                        store,
                        t.id,
                        t.name,
                        t.countUp
                            ? '正计时（自由计时）'
                            : '${t.workMinutes} / ${t.shortBreakMinutes} / ${t.longBreakMinutes} 分钟',
                        t.colorIndex,
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tune_rounded, color: AppColors.secondaryLabel),
                title: const Text('管理任务（新建 / 编辑 / 删除）'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.onOpenTasks?.call();
                },
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  /// 任务选择面板中的单行
  Widget _taskPickTile(BuildContext ctx, AppStore store, String id, String name, String subtitle, int colorIndex) {
    final bool active = store.activeTaskId == id;
    return ListTile(
      leading: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: taskColor(colorIndex), shape: BoxShape.circle),
      ),
      title: Text(name, style: const TextStyle(fontSize: 15, color: AppColors.label)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.secondaryLabel)),
      trailing: active ? const Icon(Icons.check_circle_rounded, color: AppColors.accent, size: 20) : null,
      onTap: () {
        Navigator.of(ctx).pop();
        _applyTask(id);
      },
    );
  }

  /// 打开「任务设置」弹窗：编辑【当前任务】的计时方式（倒计时 / 正计时）与三段时长
  Future<void> _openDurationSettings() async {
    final AppStore store = AppStore.instance;
    final Map<PomodoroMode, TextEditingController> controllers = <PomodoroMode, TextEditingController>{
      for (final PomodoroMode m in PomodoroMode.values)
        m: TextEditingController(text: '${store.minutesOf(m)}'),
    };
    bool countUpChoice = store.activeTaskCountUp; // 弹窗内的临时选择，点"保存"才生效

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('任务设置 · ${store.activeTaskName}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // ---- 计时方式：倒计时 / 正计时 二选一 ----
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _ChoicePill(
                        text: '倒计时',
                        selected: !countUpChoice,
                        onTap: () => setLocal(() => countUpChoice = false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ChoicePill(
                        text: '正计时',
                        selected: countUpChoice,
                        onTap: () => setLocal(() => countUpChoice = true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  countUpChoice ? '正计时不限时长，结束时按实际用时记账' : '倒计时使用下面的三段时长（分钟）',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.secondaryLabel),
                ),
                const SizedBox(height: 12),
                // ---- 三段时长（正计时任务置灰不可编辑，仅保留配置备用） ----
                Opacity(
                  opacity: countUpChoice ? 0.35 : 1,
                  child: IgnorePointer(
                    ignoring: countUpChoice,
                    child: Column(
                      children: <Widget>[
                        for (final PomodoroMode m in PomodoroMode.values) _durationField(m, controllers[m]!),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('保存')),
          ],
        ),
      ),
    );

    // 先取出输入内容，再释放控制器（避免在已 dispose 的控制器上取值）
    final Map<PomodoroMode, String> raw = <PomodoroMode, String>{
      for (final MapEntry<PomodoroMode, TextEditingController> e in controllers.entries)
        e.key: e.value.text.trim(),
    };
    for (final TextEditingController c in controllers.values) {
      c.dispose();
    }
    if (saved != true) return;

    // 解析并校验：非法输入回退为原值（范围 1~180 分钟）
    int parse(String s, int fallback) {
      final int? v = int.tryParse(s);
      if (v == null || v < 1 || v > 180) return fallback;
      return v;
    }

    await _commitAndClearSession(); // 变更前：已用时间先记账，再从 0 开始
    await store.setActiveCountUp(countUpChoice);
    await store.setActiveDurations(
      work: parse(raw[PomodoroMode.work]!, store.minutesOf(PomodoroMode.work)),
      shortBreak: parse(raw[PomodoroMode.shortBreak]!, store.minutesOf(PomodoroMode.shortBreak)),
      longBreak: parse(raw[PomodoroMode.longBreak]!, store.minutesOf(PomodoroMode.longBreak)),
    );
    if (!mounted) return;
    setState(() {
      // 变更后停止当前计时并回到干净状态（新的计时方式 / 时长立即生效）
      _ticker?.cancel();
      _ticker = null;
      _isRunning = false;
      _segmentStart = null;
      _elapsedBaseMs = 0;
      _countUp = countUpChoice;
    });
    _lastTaskId = store.activeTaskId;
    _lastCountUpSetting = countUpChoice;
    await NotificationService.instance.cancelTimerEnd();
    await _saveState();
  }

  /// 设置弹窗中的单行输入（模式图标 + 名称 + 分钟数）
  Widget _durationField(PomodoroMode mode, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(mode.icon, size: 18, color: mode.color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(mode.label, style: const TextStyle(color: AppColors.label)),
          ),
          SizedBox(
            width: 96,
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                isDense: true,
                suffixText: '分',
                contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ====================== 构建 UI ======================

  @override
  Widget build(BuildContext context) {
    // 首次进入：读取本地数据期间显示加载指示
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final Color color = _themeColor;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.white, Color.lerp(color, Colors.white, 0.86)!],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            // ---- 顶部标题栏（四页共用 _PageHeader，标题保持同一水平线） ----
            _PageHeader(
              title: '自力',
              trailing: IconButton(
                tooltip: '任务设置（时长 / 计时方式）',
                onPressed: _openDurationSettings,
                icon: const Icon(Icons.tune_rounded, color: AppColors.secondaryLabel),
              ),
            ),

            // ---- 计时模式栏：工作 / 短休息 / 长休息 / 正计时 ----
            _TimerModeBar(
              mode: _mode,
              countUp: _countUp,
              enabled: !_isRunning,
              onModeChanged: _switchMode,
              onCountUp: _switchToCountUp,
            ),

            // ---- 当前任务胶囊（点击切换任务） ----
            GestureDetector(
              onTap: _showTaskPicker,
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.flag_rounded, size: 14, color: AppColors.secondaryLabel),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 190),
                      child: Text(
                        AppStore.instance.activeTaskName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: AppColors.label),
                      ),
                    ),
                    const Icon(Icons.expand_more_rounded, size: 16, color: AppColors.secondaryLabel),
                  ],
                ),
              ),
            ),

            // ---- 圆形进度环 + 大号时间 ----
            Expanded(
              child: Center(
                child: _TimerRing(
                  progress: _progress,
                  color: color,
                  timeText: _timeText,
                  statusText: _statusText,
                  subText: _subText,
                ),
              ),
            ),

            // ---- 本轮进度圆点 + 累计计数 ----
            _StatsBar(cycleDone: _cycleDone, total: _completedCount, color: color),

            const SizedBox(height: 20),

            // ---- 控制按钮：重置 / 开始-暂停 / 跳过（正计时时右侧为"结束"） ----
            _Controls(
              running: _isRunning,
              color: color,
              rightLabel: _countUp ? '结束' : '跳过',
              rightIcon: _countUp ? Icons.stop_rounded : Icons.skip_next_rounded,
              onReset: _reset,
              onToggle: _isRunning ? _pause : _start,
              onSkip: _skip,
            ),

            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 【六】TasksPage —— 任务页
// =============================================================================

/// 任务页：创建 / 编辑 / 删除任务；点卡片 = 启用该任务并跳到计时页
class TasksPage extends StatelessWidget {
  const TasksPage({super.key, this.onOpenTimer});

  /// 启用任务后跳转到计时页的回调
  final VoidCallback? onOpenTimer;

  @override
  Widget build(BuildContext context) {
    final AppStore store = AppStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // ---- 标题栏 ----
            _PageHeader(
              title: '任务',
              trailing: TextButton.icon(
                onPressed: () => _showTaskEditor(context, null),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('新建'),
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              ),
            ),
            // ---- 任务列表 ----
            Expanded(
              child: store.tasks.isEmpty
                  ? _emptyState(context)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
                      itemCount: store.tasks.length,
                      itemBuilder: (BuildContext c, int i) => _taskCard(context, store, store.tasks[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 空状态提示
  Widget _emptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.checklist_rounded, size: 56, color: Colors.black.withValues(alpha: 0.12)),
          const SizedBox(height: 12),
          const Text('还没有任务', style: TextStyle(fontSize: 15, color: AppColors.secondaryLabel)),
          const SizedBox(height: 6),
          const Text('点右上角「新建」，比如：复习信号与系统',
              style: TextStyle(fontSize: 12.5, color: AppColors.secondaryLabel)),
        ],
      ),
    );
  }

  /// 单个任务卡片
  Widget _taskCard(BuildContext context, AppStore store, TaskItem t) {
    final bool active = store.activeTaskId == t.id;
    final int secs = store.allTimeFor(t.id);
    final Color color = taskColor(t.colorIndex);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () async {
          await store.setActiveTask(t.id);
          onOpenTimer?.call();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已切换到「${t.name}」，开始计时吧'), duration: const Duration(seconds: 2)),
            );
          }
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? color : Colors.black.withValues(alpha: 0.05),
              width: active ? 1.6 : 1,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
            ],
          ),
          child: Row(
            children: <Widget>[
              Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            t.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.label),
                          ),
                        ),
                        if (active) ...<Widget>[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text('使用中',
                                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      t.countUp
                          ? '正计时（自由计时）· 不限时长'
                          : '工作 ${t.workMinutes}分 · 短休 ${t.shortBreakMinutes}分 · 长休 ${t.longBreakMinutes}分',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.secondaryLabel),
                    ),
                    if (secs > 0) ...<Widget>[
                      const SizedBox(height: 3),
                      Text('累计专注 ${formatDuration(secs)}',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: color)),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz_rounded, color: AppColors.secondaryLabel),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onSelected: (String v) {
                  if (v == 'edit') {
                    _showTaskEditor(context, t);
                  } else {
                    _confirmDelete(context, t);
                  }
                },
                itemBuilder: (BuildContext c) => const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: 'edit', child: Text('编辑')),
                  PopupMenuItem<String>(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 新建 / 编辑任务弹窗（名称 + 计时方式 + 三段时长）
  Future<void> _showTaskEditor(BuildContext context, TaskItem? task) async {
    final AppStore store = AppStore.instance;
    final TextEditingController nameCtrl = TextEditingController(text: task?.name ?? '');
    final TextEditingController workCtrl = TextEditingController(text: '${task?.workMinutes ?? 25}');
    final TextEditingController shortCtrl = TextEditingController(text: '${task?.shortBreakMinutes ?? 5}');
    final TextEditingController longCtrl = TextEditingController(text: '${task?.longBreakMinutes ?? 15}');
    bool countUpChoice = task?.countUp ?? false; // 计时方式：false = 倒计时，true = 正计时

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(task == null ? '新建任务' : '编辑任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: '任务名称',
                    hintText: '例如：复习信号与系统',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 14),
                // ---- 计时方式：倒计时（番茄钟） / 正计时（自由计时） ----
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _ChoicePill(
                        text: '倒计时',
                        selected: !countUpChoice,
                        onTap: () => setLocal(() => countUpChoice = false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ChoicePill(
                        text: '正计时',
                        selected: countUpChoice,
                        onTap: () => setLocal(() => countUpChoice = true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  countUpChoice
                      ? '正计时不限时长：打开该任务后正着数，结束时按实际用时记账'
                      : '倒计时使用下面的三段时长（分钟）',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.secondaryLabel),
                ),
                const SizedBox(height: 12),
                // ---- 三段时长（正计时任务置灰不可编辑，仅保留配置备用） ----
                Opacity(
                  opacity: countUpChoice ? 0.35 : 1,
                  child: IgnorePointer(
                    ignoring: countUpChoice,
                    child: Column(
                      children: <Widget>[
                        _minuteRow('工作', workCtrl),
                        _minuteRow('短休息', shortCtrl),
                        _minuteRow('长休息', longCtrl),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('保存')),
          ],
        ),
      ),
    );

    // 先取文本再释放控制器
    final String rawName = nameCtrl.text.trim();
    final String rawWork = workCtrl.text.trim();
    final String rawShort = shortCtrl.text.trim();
    final String rawLong = longCtrl.text.trim();
    nameCtrl.dispose();
    workCtrl.dispose();
    shortCtrl.dispose();
    longCtrl.dispose();
    if (ok != true) return;

    int parseMin(String s, int fallback) {
      final int? v = int.tryParse(s);
      if (v == null || v < 1 || v > 180) return fallback;
      return v;
    }

    final String name = rawName.isEmpty ? '未命名任务' : rawName;
    final int work = parseMin(rawWork, 25);
    final int shortBreak = parseMin(rawShort, 5);
    final int longBreak = parseMin(rawLong, 15);

    if (task == null) {
      final TaskItem created = await store.addTask(name, work, shortBreak, longBreak, countUp: countUpChoice);
      await store.setActiveTask(created.id); // 新建后自动启用，直接就能用
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已创建并启用「$name」'), duration: const Duration(seconds: 2)),
        );
      }
    } else {
      await store.updateTask(task.copyWith(
        name: name,
        workMinutes: work,
        shortBreakMinutes: shortBreak,
        longBreakMinutes: longBreak,
        countUp: countUpChoice,
      ));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已保存「$name」'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  /// 弹窗里的单行分钟输入
  Widget _minuteRow(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(label, style: const TextStyle(fontSize: 14, color: AppColors.label)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                isDense: true,
                suffixText: '分',
                contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 删除任务确认（Apple 风格弹窗）
  Future<void> _confirmDelete(BuildContext context, TaskItem t) async {
    final AppStore store = AppStore.instance;
    final bool? del = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => cui.CupertinoAlertDialog(
        title: const Text('删除任务'),
        content: Text('「${t.name}」的计时统计也会一并删除，确定吗？'),
        actions: <Widget>[
          cui.CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          cui.CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (del == true) await store.deleteTask(t.id);
  }
}

// =============================================================================
// 【七】CheckInPage —— 自律打卡页
// =============================================================================

/// 自律打卡页：自定义每日打卡项，按天打勾，显示连续天数与最近 7 天记录
class CheckInPage extends StatelessWidget {
  const CheckInPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppStore store = AppStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? child) {
        final DateTime now = DateTime.now();
        final String today = dateKey(now);
        final int total = store.checkinItems.length;
        final int done = store.checkinItems.where((CheckInItem e) => store.isChecked(e.id, today)).length;
        final bool allDone = total > 0 && done == total;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // ---- 标题栏 ----
            _PageHeader(
              title: '自律打卡',
              trailing: TextButton.icon(
                onPressed: () => _showAddDialog(context),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('添加'),
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              ),
            ),
            // ---- 今日概况 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 2, 22, 8),
              child: Row(
                children: <Widget>[
                  Text('${now.month}月${now.day}日 · ${weekdayCn(now)}',
                      style: const TextStyle(fontSize: 13.5, color: AppColors.secondaryLabel)),
                  const Spacer(),
                  Text(
                    '今日完成 $done/$total',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: allDone ? AppColors.accent : AppColors.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            // ---- 打卡项列表 ----
            Expanded(
              child: store.checkinItems.isEmpty
                  ? _emptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
                      itemCount: store.checkinItems.length,
                      itemBuilder: (BuildContext c, int i) => _checkRow(context, store, store.checkinItems[i], today),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 空状态提示
  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.task_alt, size: 56, color: Colors.black.withValues(alpha: 0.12)),
          const SizedBox(height: 12),
          const Text('还没有打卡项', style: TextStyle(fontSize: 15, color: AppColors.secondaryLabel)),
          const SizedBox(height: 6),
          const Text('点右上角「添加」，比如：早起 / 跑步 / 背单词',
              style: TextStyle(fontSize: 12.5, color: AppColors.secondaryLabel)),
        ],
      ),
    );
  }

  /// 单个打卡项行
  Widget _checkRow(BuildContext context, AppStore store, CheckInItem item, String today) {
    final bool checked = store.isChecked(item.id, today);
    final int streak = store.streakOf(item.id);
    final List<bool> days = store.last7Days(item.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: <BoxShadow>[
            BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          children: <Widget>[
            // 圆形打勾按钮
            GestureDetector(
              onTap: () => store.toggleCheckIn(item.id, today),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: checked ? AppColors.accent : Colors.transparent,
                  shape: BoxShape.circle,
                  border: checked ? null : Border.all(color: Colors.black.withValues(alpha: 0.15), width: 1.5),
                ),
                child: checked ? const Icon(Icons.check_rounded, size: 19, color: Colors.white) : null,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(item.name,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: AppColors.label)),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Text(
                        streak > 0 ? '连续 $streak 天' : '今日开始',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: streak > 0 ? AppColors.accent : AppColors.secondaryLabel,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // 最近 7 天小圆点（旧 → 新，最右是今天）
                      for (final bool b in days)
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(right: 3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: b ? AppColors.accent : Colors.black.withValues(alpha: 0.08),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded, color: AppColors.secondaryLabel),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onSelected: (String v) => _confirmDelete(context, item),
              itemBuilder: (BuildContext c) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 添加打卡项
  Future<void> _showAddDialog(BuildContext context) async {
    final AppStore store = AppStore.instance;
    final TextEditingController nameCtrl = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('添加打卡项'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '打卡项名称',
            hintText: '例如：早起 7 点',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('添加')),
        ],
      ),
    );
    final String name = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (ok == true && name.isNotEmpty) {
      await store.addCheckInItem(name);
    }
  }

  /// 删除打卡项确认
  Future<void> _confirmDelete(BuildContext context, CheckInItem item) async {
    final AppStore store = AppStore.instance;
    final bool? del = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => cui.CupertinoAlertDialog(
        title: const Text('删除打卡项'),
        content: Text('「${item.name}」的打卡记录也会一并删除，确定吗？'),
        actions: <Widget>[
          cui.CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          cui.CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (del == true) await store.deleteCheckInItem(item.id);
  }
}

// =============================================================================
// 【八】StatsPage —— 时间统计页（扇形图）
// =============================================================================

/// 扇形图的一块数据
class _StatSlice {
  const _StatSlice({required this.name, required this.color, required this.seconds});

  final String name;
  final Color color;
  final int seconds;
}

/// 统计周期：今日 / 本周 / 本月（配合左右箭头可回看历史周期）
enum StatPeriod { day, week, month }

extension StatPeriodX on StatPeriod {
  /// 周期名称
  String get label => switch (this) {
        StatPeriod.day => '今日',
        StatPeriod.week => '本周',
        StatPeriod.month => '本月',
      };

  /// 计算周期起止日期（含端点）。[offset] = 0 表示当前周期，1 表示上一个，依此类推。
  (DateTime, DateTime) range([int offset = 0]) {
    final DateTime now = DateTime.now();
    switch (this) {
      case StatPeriod.day:
        final DateTime d = DateTime(now.year, now.month, now.day).subtract(Duration(days: offset));
        return (d, d);
      case StatPeriod.week:
        // 以周一作为一周的开始
        final DateTime monday = DateTime(now.year, now.month, now.day)
            .subtract(Duration(days: now.weekday - 1))
            .subtract(Duration(days: 7 * offset));
        return (monday, monday.add(const Duration(days: 6)));
      case StatPeriod.month:
        final DateTime first = DateTime(now.year, now.month - offset, 1);
        final DateTime last = DateTime(now.year, now.month - offset + 1, 0); // 下月 0 日 = 本月最后一天
        return (first, last);
    }
  }

  /// 周期范围的展示文案，如 9月12日 / 9月8日-9月14日
  String rangeText(int offset) {
    final (DateTime s, DateTime e) = range(offset);
    String fmt(DateTime d) => '${d.month}月${d.day}日';
    return s == e ? fmt(s) : '${fmt(s)}-${fmt(e)}';
  }
}

/// 时间统计页：按 今日 / 本周 / 本月 查看每个任务的专注时长（数据来自本地按天历史）
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  /// 当前统计周期
  StatPeriod _period = StatPeriod.day;

  /// 历史偏移：0 = 当前周期，1 = 上一个周期（用于回看历史）
  int _offset = 0;

  @override
  Widget build(BuildContext context) {
    final AppStore store = AppStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? child) {
        final (DateTime start, DateTime end) = _period.range(_offset);
        // 组装扇形图数据：默认任务 + 各任务，仅保留该周期内有记录的，按时长降序
        final List<_StatSlice> slices = <_StatSlice>[];
        void addSlice(String id, String name, int colorIndex) {
          final int s = store.secondsInRange(id, start, end);
          if (s > 0) slices.add(_StatSlice(name: name, color: taskColor(colorIndex), seconds: s));
        }

        addSlice(AppStore.defaultTaskId, AppStore.defaultTaskName, 0);
        for (final TaskItem t in store.tasks) {
          addSlice(t.id, t.name, t.colorIndex);
        }
        slices.sort((_StatSlice a, _StatSlice b) => b.seconds.compareTo(a.seconds));
        final int total = slices.fold(0, (int a, _StatSlice s) => a + s.seconds);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // ---- 标题栏 ----
            const _PageHeader(title: '时间统计'),

            // ---- 周期切换：今日 / 本周 / 本月 ----
            Container(
              margin: const EdgeInsets.fromLTRB(24, 8, 24, 2),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: <Widget>[
                  for (final StatPeriod p in StatPeriod.values)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() {
                          _period = p;
                          _offset = 0; // 切换周期类型时回到当前周期
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: p == _period ? Colors.white : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                            boxShadow: p == _period
                                ? <BoxShadow>[
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.08),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            p.label,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: p == _period ? FontWeight.w600 : FontWeight.w500,
                              color: p == _period ? AppColors.accent : AppColors.secondaryLabel,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // ---- 历史回看：左右箭头 + 日期范围 ----
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                IconButton(
                  onPressed: () => setState(() => _offset += 1),
                  icon: const Icon(Icons.chevron_left_rounded, color: AppColors.secondaryLabel),
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  tooltip: '上一个周期',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    _period.rangeText(_offset),
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: AppColors.secondaryLabel),
                  ),
                ),
                IconButton(
                  onPressed: _offset > 0 ? () => setState(() => _offset -= 1) : null,
                  icon: Icon(
                    Icons.chevron_right_rounded,
                    color: _offset > 0 ? AppColors.secondaryLabel : Colors.black.withValues(alpha: 0.12),
                  ),
                  iconSize: 22,
                  visualDensity: VisualDensity.compact,
                  tooltip: '下一个周期',
                ),
              ],
            ),

            // ---- 内容区 ----
            if (total == 0)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.pie_chart_outline, size: 56, color: Colors.black.withValues(alpha: 0.12)),
                      const SizedBox(height: 12),
                      Text(
                        _offset == 0 ? '${_period.label}还没有计时记录' : '所选周期还没有计时记录',
                        style: const TextStyle(fontSize: 15, color: AppColors.secondaryLabel),
                      ),
                      const SizedBox(height: 6),
                      const Text('完成一个番茄后，这里会显示每个任务的专注时长',
                          style: TextStyle(fontSize: 12.5, color: AppColors.secondaryLabel)),
                    ],
                  ),
                ),
              )
            else ...<Widget>[
              // ---- 扇形图 ----
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: SizedBox(
                    width: 206,
                    height: 206,
                    child: CustomPaint(painter: _PiePainter(slices)),
                  ),
                ),
              ),
              // ---- 总计 ----
              Center(
                child: Text(
                  '总计 ${formatDuration(total)}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.label),
                ),
              ),
              const SizedBox(height: 8),
              // ---- 图下明细：每个任务的具体时长 ----
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
                  itemCount: slices.length,
                  itemBuilder: (BuildContext c, int i) {
                    final _StatSlice s = slices[i];
                    final int percent = total == 0 ? 0 : ((s.seconds / total) * 100).round();
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: <Widget>[
                          Container(width: 11, height: 11, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              s.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14.5, color: AppColors.label),
                            ),
                          ),
                          Text('$percent%', style: const TextStyle(fontSize: 12, color: AppColors.secondaryLabel)),
                          const SizedBox(width: 10),
                          Text(
                            formatDuration(s.seconds),
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.label),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 扇形图画笔：按秒数比例绘制扇形（块与块之间留一条小缝，更有设计感）
class _PiePainter extends CustomPainter {
  _PiePainter(this.slices);

  /// 已按秒数降序排好的数据
  final List<_StatSlice> slices;

  @override
  void paint(Canvas canvas, Size size) {
    final double total = slices.fold(0, (int a, _StatSlice s) => a + s.seconds).toDouble();
    if (total <= 0) return;
    final Offset center = size.center(Offset.zero);
    final double radius = size.shortestSide / 2;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    final double gap = slices.length > 1 ? 0.035 : 0; // 扇形之间的缝隙（弧度）
    double start = -math.pi / 2; // 从 12 点钟方向开始
    for (final _StatSlice s in slices) {
      final double sweep = (s.seconds / total) * 2 * math.pi;
      final Paint paint = Paint()
        ..style = PaintingStyle.fill
        ..color = s.color
        ..isAntiAlias = true;
      if (sweep > gap) {
        canvas.drawArc(rect, start + gap / 2, sweep - gap, true, paint);
      } else {
        canvas.drawArc(rect, start, sweep, true, paint);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PiePainter oldDelegate) => true;
}

// =============================================================================
// 【九】共用组件与程序入口
// =============================================================================

/// 四个页面共用的标题栏：
///   · 自动避开手机状态栏（补足顶部安全区内边距，避免文字与状态栏重叠）
///   · 统一的字号 / 行高 / 边距 —— 保证各页大标题处于同一水平线
class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, this.trailing});

  /// 标题文字
  final String title;

  /// 右侧控件（按钮等，可为空）
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // 状态栏高度：计时页外层已有 SafeArea（此处取到 0），其余页面在这里补足
    final double statusBarInset = MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, statusBarInset + 8, 8, 0),
      child: SizedBox(
        height: 48,
        child: Row(
          children: <Widget>[
            Text(
              title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: AppColors.label),
            ),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 计时模式栏：工作 / 短休息 / 长休息 / 正计时（四段式，Apple 分段控件风格）
class _TimerModeBar extends StatelessWidget {
  const _TimerModeBar({
    required this.mode,
    required this.countUp,
    required this.enabled,
    required this.onModeChanged,
    required this.onCountUp,
  });

  /// 当前倒计时模式
  final PomodoroMode mode;

  /// 是否处于正计时（自由计时）
  final bool countUp;

  /// 是否允许切换（计时运行中为 false，防止误触）
  final bool enabled;

  /// 切换到某个倒计时模式
  final ValueChanged<PomodoroMode> onModeChanged;

  /// 切换到正计时
  final VoidCallback onCountUp;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          for (final PomodoroMode m in PomodoroMode.values)
            _item(m.label, m.color, !countUp && mode == m, () => onModeChanged(m)),
          _item('正计时', AppColors.accent, countUp, onCountUp),
        ],
      ),
    );
  }

  /// 单个分段
  Widget _item(String label, Color color, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            // 选中的一项浮起为白色卡片（iOS 分段控件特征）
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? color : AppColors.secondaryLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆形进度环 + 中央大号时间显示
class _TimerRing extends StatelessWidget {
  const _TimerRing({
    required this.progress,
    required this.color,
    required this.timeText,
    required this.statusText,
    required this.subText,
  });

  /// 剩余比例（0.0 ~ 1.0）
  final double progress;

  /// 模式主题色
  final Color color;

  /// 时间文本，如 24:59
  final String timeText;

  /// 状态文本，如"专注中"
  final String statusText;

  /// 底部小字说明
  final String subText;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 292,
      height: 292,
      child: CustomPaint(
        painter: _RingPainter(progress: progress, color: color),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              statusText,
              style: const TextStyle(fontSize: 15, letterSpacing: 2, color: AppColors.secondaryLabel),
            ),
            const SizedBox(height: 8),
            // 大号时间：细字重 + 等宽数字，模仿 iOS 计时器
            Text(
              timeText,
              style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.w200,
                height: 1.05,
                letterSpacing: 1,
                color: AppColors.label,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            Text(subText, style: const TextStyle(fontSize: 13, color: AppColors.secondaryLabel)),
          ],
        ),
      ),
    );
  }
}

/// 圆环画笔：底环 + 按剩余比例的进度弧（12 点钟方向起，顺时针）
class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color});

  /// 剩余比例 0.0 ~ 1.0
  final double progress;

  /// 进度弧颜色
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double strokeWidth = 16;
    final Offset center = size.center(Offset.zero);
    final double radius = (size.shortestSide - strokeWidth) / 2;

    // 1) 底环：主题色的极浅色（表示"总时长"）
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.12);
    canvas.drawCircle(center, radius, track);

    // 2) 进度弧：剩余时间比例（剩余为 0 时不画）
    if (progress > 0) {
      final Paint arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color;
      const double startAngle = -math.pi / 2; // 12 点钟方向
      final double sweepAngle = 2 * math.pi * progress; // 顺时针扫过
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        arc,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

/// 本轮进度（4 个圆点）+ 累计番茄数
class _StatsBar extends StatelessWidget {
  const _StatsBar({
    required this.cycleDone,
    required this.total,
    required this.color,
  });

  /// 本轮已完成数（0~4）
  final int cycleDone;

  /// 累计完成数
  final int total;

  /// 主题色
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            for (int i = 0; i < 4; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: i < cycleDone ? 26 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: i < cycleDone ? color : color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '累计完成 $total 个番茄',
          style: const TextStyle(fontSize: 14, color: AppColors.secondaryLabel),
        ),
      ],
    );
  }
}

/// 小胶囊选择按钮（Apple 风格）：用于"倒计时 / 正计时"二选一
class _ChoicePill extends StatelessWidget {
  const _ChoicePill({required this.text, required this.selected, required this.onTap});

  /// 按钮文字
  final String text;

  /// 是否选中
  final bool selected;

  /// 点击回调
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: 0.14) : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.accent : Colors.transparent,
            width: 1.2,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? AppColors.accent : AppColors.secondaryLabel,
          ),
        ),
      ),
    );
  }
}

/// 底部控制区：重置 / 开始-暂停（大按钮）/ 跳过（正计时下显示为"结束"）
class _Controls extends StatelessWidget {
  const _Controls({
    required this.running,
    required this.color,
    required this.rightLabel,
    required this.rightIcon,
    required this.onReset,
    required this.onToggle,
    required this.onSkip,
  });

  /// 是否正在运行（决定中间按钮显示"暂停"还是"开始"）
  final bool running;

  /// 主题色
  final Color color;

  /// 右侧按钮文案：倒计时 = 跳过；正计时 = 结束
  final String rightLabel;

  /// 右侧按钮图标
  final IconData rightIcon;

  final VoidCallback onReset;
  final VoidCallback onToggle;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        // 次级按钮：重置
        _CircleButton(
          icon: Icons.refresh_rounded,
          label: '重置',
          size: 58,
          onTap: onReset,
        ),

        // 主按钮：开始 / 暂停（带主题色阴影的大圆形按钮）
        GestureDetector(
          onTap: onToggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Icon(
              running ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 46,
              color: Colors.white,
            ),
          ),
        ),

        // 次级按钮：跳过（倒计时）/ 结束（正计时）
        _CircleButton(
          icon: rightIcon,
          label: rightLabel,
          size: 58,
          onTap: onSkip,
        ),
      ],
    );
  }
}

/// 次级圆形按钮（白色圆 + 图标 + 下方文字）
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.label,
    required this.size,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, size: size * 0.44, color: AppColors.label),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.secondaryLabel)),
      ],
    );
  }
}

// =============================================================================
// 程序入口
// =============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // 读取全部本地数据（任务 / 打卡 / 统计）
    await AppStore.instance.load();
  } catch (_) {
    // 数据读取失败不阻塞启动（各页面有默认值兜底）
  }
  try {
    // 初始化本地通知插件（后台计时提醒的基础设施）
    await NotificationService.instance.init();
  } catch (_) {
    // 通知初始化失败不影响主功能（前台震动 + 铃声依然可用）
  }
  runApp(const PomodoroApp());
}

/// 应用根组件
class PomodoroApp extends StatelessWidget {
  const PomodoroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '自力',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.accent),
        scaffoldBackgroundColor: AppColors.pageBackground,
        // 中文字体优先使用各厂商的系统 UI 字体（观感更接近 iOS/鸿蒙）
        fontFamilyFallback: const <String>[
          'PingFang SC',
          'HarmonyOS Sans SC',
          'MiSans',
          'Source Han Sans SC',
        ],
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      home: const HomeShell(),
    );
  }
}
