import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

late final RealtimeChannel _channel;
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

class PatientRecordsScreen extends StatefulWidget {
  const PatientRecordsScreen({Key? key}) : super(key: key);

  @override
  State<PatientRecordsScreen> createState() => _PatientRecordsScreenState();
}

class _PatientRecordsScreenState extends State<PatientRecordsScreen> {
  List<Map<String, dynamic>> records = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    fetchRecords();
    listenToRealtimeChanges();
  }

  Future<void> _initNotifications() async {
    // Step 1: Xin quyền trước (Android 13+)
    final status = await Permission.notification.request();
    print("🔔 Notification permission granted? ${status.isGranted}");

    // Step 2: Init plugin như cũ
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  Future<void> _showLocalNotification(String title, String body) async {
    print("🔔 SHOW NOTIFICATION: $title - $body"); // thêm dòng này
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
          'critical_channel_id',
          'Critical Alerts',
          channelDescription:
              'Notification when a critical patient record is inserted',
          importance: Importance.max,
          priority: Priority.high,
          showWhen: true,
        );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.show(
      0,
      title,
      body,
      platformChannelSpecifics,
    );
  }

  Future<void> fetchRecords() async {
    final supabase = Supabase.instance.client;

    final response = await supabase
        .from('patient_records')
        .select()
        .order('timestamp', ascending: false);

    final fetchedRecords = List<Map<String, dynamic>>.from(response);

    setState(() {
      records = fetchedRecords;
      isLoading = false;
    });

    // Kiểm tra nếu có critical chưa check
    final firstUnchecked = records.firstWhere(
      (r) => r['status'] == 'critical' && r['is_checked'] == false,
      orElse: () => {},
    );

    if (firstUnchecked.isNotEmpty && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDialog(
          context: context,
          builder:
              (_) => AlertDialog(
                title: const Text("⚠️ Unchecked Critical Alert"),
                content: const Text("There is an critical situation that's not check."),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);

                      // Scroll tới record đó (nếu visible)
                      final index = records.indexOf(firstUnchecked);
                      if (index >= 0) {
                        Scrollable.ensureVisible(
                          context,
                          duration: const Duration(milliseconds: 500),
                          alignment: 0.5,
                        );
                      }
                    },
                    child: const Text("Check"),
                  ),
                ],
              ),
        );
      });
    }
  }

  void listenToRealtimeChanges() {
    final supabase = Supabase.instance.client;

    _channel = supabase.channel('public:patient_records');

    _channel
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'patient_records',
          callback: (payload) async {
            if (payload.newRecord == null) return;
            final newRecord = Map<String, dynamic>.from(payload.newRecord!);

            setState(() {
              records.insert(0, newRecord);
            });

            // Hiện alert nếu status là 'critical' và chưa checked
            if (newRecord['status'] == 'critical' &&
                newRecord['is_checked'] == false) {
              await _showLocalNotification(
                "🚨 Critical Alert",
                "New patient behavior: ${newRecord['behavior']}",
              );

              final timestamp = newRecord['timestamp'];
              final imageId = newRecord['image_id'];
              final recordId = newRecord['id'];

              showDialog(
                context: context,
                builder:
                    (_) => AlertDialog(
                      title: const Text("🚨 Critical Behavior Detected"),
                      content: Text("Time: $timestamp"),
                      actions: [
                        TextButton(
                          onPressed: () async {
                            Navigator.pop(context);

                            // Cập nhật is_checked = true
                            await supabase
                                .from('patient_records')
                                .update({'is_checked': true})
                                .eq('id', recordId);

                            final image = await fetchImageById(imageId);
                            if (!mounted) return;

                            showDialog(
                              context: context,
                              builder:
                                  (_) => AlertDialog(
                                    title: const Text("📷 Related Image"),
                                    content:
                                        image != null
                                            ? Image.network(image['url'])
                                            : const Text("Image not found."),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text("Close"),
                                      ),
                                    ],
                                  ),
                            );
                          },
                          child: const Text("Okay"),
                        ),
                      ],
                    ),
              );
            }
          },
        )
        .subscribe();
  }

  Future<Map<String, dynamic>?> fetchImageById(int imageId) async {
    final supabase = Supabase.instance.client;

    try {
      final response =
          await supabase
              .from('images')
              .select()
              .eq('id', imageId)
              .limit(1)
              .maybeSingle();

      return response;
    } catch (e) {
      print("❌ fetchImageById failed: $e");
      return null;
    }
  }

  @override
  void dispose() {
    _channel.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasUnresolvedCritical = records.any(
      (r) => r['status'] == 'critical' && r['is_checked'] == false,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text("Patient Records for P026"),
        backgroundColor: hasUnresolvedCritical ? Colors.red : null,
      ),
      body:
          isLoading
              ? const Center(child: CircularProgressIndicator())
              : Container(
                decoration: BoxDecoration(
                  color:
                      hasUnresolvedCritical
                          ? Colors.red.shade50
                          : Colors.grey.shade100,
                  border:
                      hasUnresolvedCritical
                          ? Border.all(color: Colors.red, width: 4)
                          : null,
                ),
                child: ListView.builder(
                  itemCount: records.length,
                  itemBuilder: (context, index) {
                    final record = records[index];
                    final isCritical = record['status'] == 'critical';
                    final isUnchecked = record['is_checked'] == false;
                    final rowBackground =
                        isCritical && isUnchecked
                            ? Colors
                                .red
                                .shade100 // hoặc Colors.red.shade50 để nhẹ hơn
                            : isCritical
                            ? Colors.red.shade50
                            : null;
                    return ListTile(
                      onTap: () async {
                        final imageId = record['image_id'];
                        if (imageId == null) return;

                        final image = await fetchImageById(imageId);
                        if (!mounted) return;

                        showDialog(
                          context: context,
                          builder:
                              (_) => AlertDialog(
                                title: const Text("📷 Image & Details"),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (image != null)
                                      Image.network(image['url']),
                                    const SizedBox(height: 10),
                                    Text("🧠 ${record['behavior']}"),
                                    Text("🎯 ${record['confidence']}%"),
                                    Text("⏰ ${record['timestamp']}"),
                                    Text("📍 ${record['status']}"),
                                  ],
                                ),
                                actions: [
                                  if (record['status'] == 'critical' &&
                                      record['is_checked'] == false)
                                    TextButton(
                                      onPressed: () async {
                                        final supabase =
                                            Supabase.instance.client;
                                        await supabase
                                            .from('patient_records')
                                            .update({'is_checked': true})
                                            .eq('id', record['id']);
                                        Navigator.pop(context);
                                        fetchRecords(); // Refresh lại sau khi check
                                      },
                                      child: const Text("✔ Mark Checked"),
                                    ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text("Close"),
                                  ),
                                ],
                              ),
                        );
                      },
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      tileColor: rowBackground,
                      title: Text(
                        "👤 ${record['status']}",
                        style: TextStyle(
                          fontWeight:
                              isCritical && isUnchecked
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                        ),
                      ),

                      subtitle: Text(
                        "🧠 ${record['behavior']} – 🎯 ${record['confidence']}%",
                      ),
                      trailing: Text("${record['timestamp']}"),
                    );
                  },
                ),
              ),
    );
  }
}
