import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';

// Conditional import for responsive image
import '../widgets/responsive_image_stub.dart'
  if (dart.library.html) '../widgets/responsive_image_web.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Global flag to track if critical alert has been shown (runtime only)
class _CriticalAlertTracker {
  static bool _hasShownAlert = false;
  
  static bool get hasShownAlert => _hasShownAlert;
  
  static void markAlertAsShown() {
    _hasShownAlert = true;
    print("🚨 Critical alert marked as shown for this app session");
  }
  
  static void resetAlert() {
    _hasShownAlert = false;
    print("🔄 Critical alert flag reset");
  }
}

// Camera data model
class Camera {
  final String imouId;
  final String name;

  Camera({required this.imouId, required this.name});

  factory Camera.fromJson(Map<String, dynamic> json) {
    return Camera(
      imouId: json['imou_id'] as String,
      name: json['name'] as String,
    );
  }
}

class PatientRecordsScreen extends StatefulWidget {
  final dynamic patientId; // Can be int, String, or null to handle large integers
  final String? patientCode;
  final String? patientDisplayName;
  final String? patientName;
  final String? patientAvatar;
  final String? roomNumber;
  final int? criticalUnresolvedCount;

  const PatientRecordsScreen({
    super.key,
    this.patientId,
    this.patientCode,
    this.patientDisplayName,
    this.patientName,
    this.patientAvatar,
    this.roomNumber,
    this.criticalUnresolvedCount,
  });

  @override
  State<PatientRecordsScreen> createState() => _PatientRecordsScreenState();
}

class _PatientRecordsScreenState extends State<PatientRecordsScreen>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> records = [];
  List<Camera> cameras = [];
  bool isLoading = true;
  bool camerasLoaded = false;
  TabController? _tabController;
  RealtimeChannel? _channel;

  // Patient info
  late String patientCode;
  late String patientDisplayName;
  late String patientName;
  late String patientAvatar;
  late String roomNumber;
  late int initialCriticalCount;
  
  // Patient settings
  dynamic patientId; // Can be int or String to handle large integers
  bool isConvulsionObserve = false;
  bool settingsLoading = false;

  @override
  void initState() {
    super.initState();
    _initializePatientInfo();
    _initNotifications();
    _initializeData();
  }

  void _initializePatientInfo() {
    patientId = widget.patientId;
    patientCode = widget.patientCode ?? 'P026';
    patientDisplayName = widget.patientDisplayName ?? 'P026 – Đột quỵ';
    patientName = widget.patientName ?? '';
    patientAvatar = widget.patientAvatar ?? 'https://via.placeholder.com/150';
    roomNumber = widget.roomNumber ?? 'Room: 321';
    initialCriticalCount = widget.criticalUnresolvedCount ?? 0;
  }

  // Helper functions
  String formatNote(String? note) {
    if (note == null || note.isEmpty) return 'No note';
    final cleaned = note.replaceAll('"', '').trim();
    if (cleaned.isEmpty) return 'No note';
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }

  String formatVietnameseDateTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return 'Unknown';
    try {
      final dateTime = DateTime.parse(timestamp).toUtc().toLocal();
      return DateFormat('dd/MM/yyyy HH:mm').format(dateTime);
    } catch (e) {
      print("❌ Failed to parse timestamp: $timestamp");
      return 'Invalid date';
    }
  }

  // Patient ID and settings operations
  Future<void> _getPatientId() async {
    try {
      final supabase = Supabase.instance.client;
      final response = await supabase
          .from('patients')
          .select('patient_id::text')
          .eq('code', patientCode)
          .limit(1)
          .maybeSingle();

      if (response != null) {
        setState(() {
          patientId = response['patient_id']; // Already a string from ::text cast
        });
        print("✅ Patient ID found: $patientId (type: ${patientId.runtimeType}) for code: $patientCode");
      } else {
        throw Exception("Patient with code $patientCode not found");
      }
    } catch (e) {
      print("❌ Failed to get patient ID: $e");
      throw e;
    }
  }

  Future<void> _loadPatientSettings() async {
    if (patientId == null) {
      print("❌ Cannot load patient settings: patientId is null");
      return;
    }
    
    try {
      setState(() {
        settingsLoading = true;
      });

      print("🔄 Loading patient settings for patientId: $patientId");

      final supabase = Supabase.instance.client;
      final response = await supabase
          .from('patient_settings')
          .select('isConvulsionObserve')
          .eq('patient_id', patientId!)
          .limit(1)
          .maybeSingle();

      if (response != null) {
        // Settings found, update the toggle state
        setState(() {
          isConvulsionObserve = response['isConvulsionObserve'] as bool? ?? false;
          settingsLoading = false;
        });
        print("✅ Patient settings loaded: isConvulsionObserve = $isConvulsionObserve");
      } else {
        // No settings found, just set default without creating
        setState(() {
          isConvulsionObserve = false;
          settingsLoading = false;
        });
        print("✅ No existing patient settings found, using default: isConvulsionObserve = false");
      }
    } catch (e) {
      print("❌ Failed to load patient settings for patientId=$patientId: $e");
      setState(() {
        isConvulsionObserve = false;
        settingsLoading = false;
      });
      if (mounted) {
        _showErrorDialog(
          "Settings Error",
          "Failed to load patient settings for patient ID $patientId: ${e.toString()}",
        );
      }
    }
  }

  Future<void> _createPatientSettings(bool convulsionObserve) async {
    if (patientId == null) {
      print("❌ Cannot create patient settings: patientId is null");
      return;
    }

    try {
      print("🔄 Creating patient settings for patientId: $patientId, convulsionObserve: $convulsionObserve");
      
      final supabase = Supabase.instance.client;
      
      // Double-check that the patient exists before inserting settings
      final patientCheck = await supabase
          .from('patients')
          .select('patient_id::text, code')
          .eq('patient_id', patientId!)
          .limit(1)
          .maybeSingle();
      
      if (patientCheck == null) {
        throw Exception("Patient ID $patientId does not exist in patients table");
      }
      
      print("✅ Patient verified: ID $patientId, Code: ${patientCheck['code']}");
      
      // Now create the settings
      await supabase
          .from('patient_settings')
          .insert({
            'patient_id': patientId,
            'isConvulsionObserve': convulsionObserve,
          });

      setState(() {
        isConvulsionObserve = convulsionObserve;
        settingsLoading = false;
      });
      print("✅ Patient settings created successfully: patientId=$patientId, isConvulsionObserve=$convulsionObserve");
    } catch (e) {
      print("❌ Failed to create patient settings for patientId=$patientId: $e");
      setState(() {
        settingsLoading = false;
      });
      if (mounted) {
        _showErrorDialog(
          "Settings Error",
          "Failed to create patient settings for patient ID $patientId: ${e.toString()}",
        );
      }
    }
  }

  Future<void> _updatePatientSettings(bool convulsionObserve) async {
    if (patientId == null) return;

    try {
      setState(() {
        settingsLoading = true;
      });

      final supabase = Supabase.instance.client;
      
      // Check if settings exist
      final existingSettings = await supabase
          .from('patient_settings')
          .select('patient_id')
          .eq('patient_id', patientId!)
          .limit(1)
          .maybeSingle();
      print("🔄 Checking existing settings for patientId: $patientId");
      if (existingSettings != null) {
        // Update existing settings
        await supabase
            .from('patient_settings')
            .update({'isConvulsionObserve': convulsionObserve})
            .eq('patient_id', patientId!);
        print("✅ Patient settings updated: isConvulsionObserve = $convulsionObserve");
      } else {
        // Create new settings
        await supabase
            .from('patient_settings')
            .insert({
              'patient_id': patientId!,
              'isConvulsionObserve': convulsionObserve,
            });
        print("✅ Patient settings created: isConvulsionObserve = $convulsionObserve");
      }

      setState(() {
        isConvulsionObserve = convulsionObserve;
        settingsLoading = false;
      });
    } catch (e) {
      print("❌ Failed to update patient settings: $e");
      setState(() {
        settingsLoading = false;
      });
      if (mounted) {
        _showErrorDialog(
          "Settings Error",
          "Failed to update patient settings: ${e.toString()}",
        );
      }
    }
  }

  // Data operations
  Future<void> _initializeData() async {
    try {
      // Always validate the patient ID by looking it up from the database
      // This ensures we have the correct, valid patient_id that exists in the patients table
      await _getPatientId();
      
      if (patientId != null) {
        print("✅ Using validated patient ID: $patientId for code: $patientCode");
        
        // Verify the patient ID exists in the patients table before proceeding
        final supabase = Supabase.instance.client;
        final patientExists = await supabase
            .from('patients')
            .select('patient_id')
            .eq('patient_id', patientId!)
            .limit(1)
            .maybeSingle();
        
        if (patientExists == null) {
          throw Exception("Patient ID $patientId does not exist in the patients table");
        }
        
        print("✅ Patient ID $patientId verified in patients table");
        
        // Load patient settings and cameras
        await _loadPatientSettings();
        await loadCameras();
        if (cameras.isNotEmpty) {
          _tabController = TabController(length: cameras.length, vsync: this);
          setState(() {
            camerasLoaded = true;
          });
          await fetchRecords();
          listenToRealtimeChanges();
        } else {
          setState(() {
            camerasLoaded = true;
          });
        }
      } else {
        throw Exception("Patient not found");
      }
    } catch (e) {
      print("❌ Failed to initialize data: $e");
      if (mounted) {
        _showErrorDialog(
          "Failed to load data",
          "Unable to retrieve patient information, cameras and records. Please try again.\n\nError: ${e.toString()}",
        );
      }
    }
  }

  Future<void> loadCameras() async {
    if (patientId == null) return;
    
    try {
      final supabase = Supabase.instance.client;
      final response = await supabase
          .from('cameras')
          .select('imou_id, name')
          .eq('patient_id', patientId!)
          .order('name', ascending: true);

      final fetchedCameras = List<Map<String, dynamic>>.from(response);
      
      if (mounted) {
        setState(() {
          cameras = fetchedCameras.map((json) => Camera.fromJson(json)).toList();
        });
      }
      print("✅ Loaded ${cameras.length} cameras for patient ID: $patientId");
    } catch (e) {
      print("❌ Failed to load cameras: $e");
      if (mounted) {
        _showErrorDialog(
          "Failed to load cameras",
          "Unable to retrieve camera list from database: ${e.toString()}",
        );
      }
    }
  }

  Future<void> fetchRecords() async {
    try {
      final supabase = Supabase.instance.client;
      final response = await supabase
          .from('patient_records')
          .select()
          .eq('patient_code', patientCode) // Filter by current patient
          .order('timestamp', ascending: false);

      final fetchedRecords = List<Map<String, dynamic>>.from(response);

      if (mounted) {
        setState(() {
          records = fetchedRecords;
          isLoading = false;
        });
        checkForCriticalRecords();
      }
    } catch (e) {
      print("❌ Failed to fetch records: $e");
      if (mounted) {
        setState(() => isLoading = false);
        _showErrorDialog(
          "Failed to load records",
          "Something wrong, cannot get patient records: ${e.toString()}",
        );
      }
    }
  }

  Future<Map<String, dynamic>?> fetchImageById(int imageId) async {
    try {
      final supabase = Supabase.instance.client;
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

  // Notification methods
  Future<void> _initNotifications() async {
    try {
      final status = await Permission.notification.request();
      print("🔔 Notification permission granted? ${status.isGranted}");

      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      const InitializationSettings initializationSettings =
          InitializationSettings(android: initializationSettingsAndroid);

      await flutterLocalNotificationsPlugin.initialize(initializationSettings);
    } catch (e) {
      print("❌ Notification initialization failed: $e");
    }
  }

  Future<void> _showLocalNotification(String title, String body) async {
    try {
      print("🔔 SHOW NOTIFICATION: $title - $body");
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
    } catch (e) {
      print("❌ Failed to show notification: $e");
    }
  }

  // Realtime and critical alerts
  void listenToRealtimeChanges() {
    try {
      if (_channel != null) {
        _channel!.unsubscribe();
        _channel = null;
      }

      final supabase = Supabase.instance.client;
      final channelName =
          'patient_records_${DateTime.now().millisecondsSinceEpoch}';
      _channel = supabase.channel(channelName);

      _channel!
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'patient_records',
            callback: (payload) async {
              try {
                if (payload.newRecord == null || !mounted) return;

                final newRecord = Map<String, dynamic>.from(payload.newRecord!);

                // Only add records for current patient
                if (newRecord['patient_code'] == patientCode) {
                  if (mounted) {
                    setState(() => records.insert(0, newRecord));

                    if (newRecord['status'] == 'critical' &&
                        newRecord['is_checked'] == false) {
                      await _showLocalNotification(
                        "Critical Alert",
                        "New critical patient behavior detected for $patientDisplayName",
                      );
                    }
                  }
                }
              } catch (e) {
                print("❌ Failed to handle realtime change: $e");
              }
            },
          )
          .subscribe();
    } catch (e) {
      print("❌ Failed to setup realtime listener: $e");
      if (mounted) {
        _showErrorDialog(
          "Connection Error",
          "Failed to setup real-time monitoring: ${e.toString()}",
        );
      }
    }
  }

  void checkForCriticalRecords() {
    try {
      if (_tabController == null || cameras.isEmpty) return;
      
      // Check if alert has already been shown this session
      if (_CriticalAlertTracker.hasShownAlert) {
        print("⏭️ Critical alert already shown this session, skipping");
        return;
      }
      
      final String currentCameraImouId = cameras[_tabController!.index].imouId;
      final currentCameraRecords =
          records
              .where((record) => record['camera_imou_id'] == currentCameraImouId)
              .toList();

      Map<String, dynamic>? firstUnchecked;
      for (var record in currentCameraRecords) {
        if (record['status'] == 'critical' && record['is_checked'] == false) {
          firstUnchecked = record;
          break;
        }
      }

      if (firstUnchecked != null && mounted && !_CriticalAlertTracker.hasShownAlert) {
        print("🚨 Found unchecked critical record, showing alert dialog");
        
        // Mark alert as shown before displaying to prevent duplicate calls
        _CriticalAlertTracker.markAlertAsShown();
        
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            showGeneralDialog(
              context: context,
              barrierDismissible: true,
              barrierLabel: '',
              barrierColor: Colors.black54,
              transitionDuration: const Duration(milliseconds: 300),
              transitionBuilder: (context, animation, secondaryAnimation, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: const Offset(0, 0),
                  ).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeInOut),
                  ),
                  child: child,
                );
              },
              pageBuilder: (context, animation, secondaryAnimation) {
                return Center(
                  child: Material(
                    type: MaterialType.transparency,
                    child: Container(
                      margin: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.warning, color: Colors.red, size: 48),
                            const SizedBox(height: 16),
                            Text(
                              "Unchecked Critical Alert - ${cameras[_tabController!.index].name}",
                              style: const TextStyle(
                                color: Colors.red,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              "There are unresolved critical events that require your attention.",
                              style: TextStyle(fontSize: 16),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text("Later"),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(context),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blue,
                                  ),
                                  child: const Text("Check Now"),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          }
        });
      } else if (firstUnchecked == null) {
        print("✅ No unchecked critical records found for current camera");
      }
    } catch (e) {
      print("❌ Failed to check critical records: $e");
    }
  }

  // Utility methods
  List<Map<String, dynamic>> getRecordsForCamera(String cameraImouId) {
    return records.where((record) => record['camera_imou_id'] == cameraImouId).toList();
  }

  bool hasUnresolvedCriticalForCamera(String cameraImouId) {
    return getRecordsForCamera(
      cameraImouId,
    ).any((r) => r['status'] == 'critical' && r['is_checked'] == false);
  }

  int getUnresolvedCriticalCountForCamera(String cameraImouId) {
    return getRecordsForCamera(cameraImouId)
        .where((r) => r['status'] == 'critical' && r['is_checked'] == false)
        .length;
  }

  // Dialog methods
  void _showErrorDialog(String title, String message) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: const Offset(0, 0),
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          ),
          child: child,
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return Center(
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              margin: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.red,
                          size: 48,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(message, style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Possible reasons:",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.red,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text("• Cannot get patient ID"),
                          Text("• Network connectivity issues"),
                          Text("• Server is temporarily unavailable"),
                          Text("• Invalid patient session"),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            Navigator.of(context).pop();
                          },
                          child: const Text("Back to Patient List"),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _initializeData();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                          ),
                          child: const Text("Retry"),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showRecordDetailsDialog(
    Map<String, dynamic> record,
    Map<String, dynamic>? image,
  ) {
    final isCritical = record['status'] == 'critical';
    final isUnchecked = record['is_checked'] == false;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1), // Start from bottom
            end: const Offset(0, 0), // End at center
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeInOut),
          ),
          child: child,
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return Center(
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              margin: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Text(
                        "Patient Record Details",
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (image != null) _buildImageSection(image),
                    _buildRecordDetailsSection(record, isCritical),
                    const SizedBox(height: 16),
                    _buildDialogActions(record, isCritical, isUnchecked),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildImageSection(Map<String, dynamic> image) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      child: buildResponsiveImage(context, image['url']),
    );
  }

  Widget _buildRecordDetailsSection(
    Map<String, dynamic> record,
    bool isCritical,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildDetailRowEnhanced(context, "Note", formatNote(record['note'])),
          _buildDetailRowEnhanced(
            context,
            "Time",
            formatVietnameseDateTime(record['timestamp']),
          ),
          _buildDetailRowEnhanced(
            context,
            "Status",
            record['status'] ?? 'Unknown',
            isHighlighted: isCritical,
          ),
        ],
      ),
    );
  }

  Widget _buildDialogActions(
    Map<String, dynamic> record,
    bool isCritical,
    bool isUnchecked,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (isCritical && isUnchecked)
          ElevatedButton(
            onPressed: () => _markAsChecked(record),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text("Mark as Checked"),
          ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Close"),
        ),
      ],
    );
  }

  Future<void> _markAsChecked(Map<String, dynamic> record) async {
    try {
      final supabase = Supabase.instance.client;
      await supabase
          .from('patient_records')
          .update({'is_checked': true})
          .eq('id', record['id']);
      Navigator.pop(context);
      fetchRecords();
    } catch (e) {
      print("❌ Failed to update record: $e");
    }
  }

  // Widget builders
  Widget _buildPatientHeader() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: Colors.grey.shade200,
                backgroundImage: NetworkImage(patientAvatar),
                onBackgroundImageError: (_, __) {},
                child:
                    patientAvatar.contains('placeholder')
                        ? Icon(Icons.person, size: 30, color: Colors.grey.shade600)
                        : null,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      patientDisplayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      roomNumber,
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.monitor_heart,
                      size: 16,
                      color: Colors.green.shade700,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      "Monitoring",
                      style: TextStyle(
                        color: Colors.green.shade700,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Convulsion Observe Toggle with Smooth Animations
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
            boxShadow: [
              BoxShadow(
                color: Colors.grey.shade200,
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            children: [
              // Animated Icon with smooth transition
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (Widget child, Animation<double> animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: animation,
                      child: child,
                    ),
                  );
                },
                child: Icon(
                  isConvulsionObserve ? Icons.visibility : Icons.visibility_off,
                  key: ValueKey<bool>(isConvulsionObserve),
                  color: isConvulsionObserve ? Colors.orange[700] : Colors.grey,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Convulsion Observe",
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // Animated status text
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Text(
                        isConvulsionObserve 
                            ? "Enhanced monitoring active" 
                            : "Normal monitoring",
                        key: ValueKey<String>(
                          isConvulsionObserve 
                              ? "Enhanced monitoring active" 
                              : "Normal monitoring"
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Animated loading indicator or switch
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: settingsLoading
                    ? SizedBox(
                        key: const ValueKey('loading'),
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.orange[700]!),
                        ),
                      )
                    : Switch(
                        key: const ValueKey('switch'),
                        value: isConvulsionObserve,
                        onChanged: patientId != null && !settingsLoading 
                            ? (bool value) {
                                _updatePatientSettings(value);
                              }
                            : null, // Disable switch if no valid patient ID or loading
                        activeColor: Colors.orange[700],
                        activeTrackColor: Colors.orange[200],
                        inactiveThumbColor: Colors.grey.shade400,
                        inactiveTrackColor: Colors.grey.shade200,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    if (_tabController == null || cameras.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      color: Colors.white,
      child: TabBar(
        controller: _tabController,
        onTap: (index) {
          Future.delayed(const Duration(milliseconds: 300), () {
            checkForCriticalRecords();
          });
        },
        tabs:
            cameras.map((camera) {
              final criticalCount = getUnresolvedCriticalCountForCamera(camera.imouId);
              return Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(camera.name),
                    if (criticalCount > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          criticalCount.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
      ),
    );
  }

  Widget _buildCameraTab(Camera camera) {
    final cameraRecords = getRecordsForCamera(camera.imouId);
    final hasCritical = hasUnresolvedCriticalForCamera(camera.imouId);

    return Container(
      color: Colors.grey.shade50,
      child: Column(
        children: [
          if (hasCritical) _buildCriticalAlert(camera),
          Expanded(
            child:
                cameraRecords.isEmpty
                    ? Center(
                      child: Text(
                        "No records for ${camera.name}",
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 16,
                        ),
                      ),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: cameraRecords.length,
                      itemBuilder:
                          (context, index) =>
                              _buildRecordCard(cameraRecords[index]),
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildCriticalAlert(Camera camera) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: Colors.red.shade50,
      child: Row(
        children: [
          const Icon(Icons.warning, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Critical alerts detected in ${camera.name}",
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(Map<String, dynamic> record) {
    final isCritical = record['status'] == 'critical';
    final isUnchecked = record['is_checked'] == false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side:
              isCritical
                  ? BorderSide(
                    color: isUnchecked ? Colors.red : Colors.red.shade200,
                    width: isUnchecked ? 3.0 : 1.5,
                  )
                  : BorderSide.none,
        ),
        child: InkWell(
          onTap: () => _handleRecordTap(record),
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Status: ${(record['status'] ?? 'Unknown').toString().toUpperCase()}",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color:
                            isCritical ? Colors.red.shade700 : Colors.black87,
                      ),
                    ),
                    _buildStatusBadge(isCritical, isUnchecked),
                  ],
                ),
                const SizedBox(height: 8),
                _buildRecordRow("Note", formatNote(record['note'])),
                _buildRecordRow(
                  "Time",
                  formatVietnameseDateTime(record['timestamp']),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(bool isCritical, bool isUnchecked) {
    if (!isCritical) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isUnchecked ? Colors.red : Colors.green,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        isUnchecked ? "Unresolved" : "Resolved",
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Future<void> _handleRecordTap(Map<String, dynamic> record) async {
    try {
      final imageId = record['image_id'];
      if (imageId == null) return;

      final image = await fetchImageById(imageId);
      if (!mounted) return;

      _showRecordDetailsDialog(record, image);
    } catch (e) {
      print("❌ Failed to show record details: $e");
    }
  }

  Widget _buildRecordRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(color: Colors.black87),
          children: [
            TextSpan(
              text: "$label: ",
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.black54,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(color: Colors.black87),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRowEnhanced(
    BuildContext context,
    String label,
    String value, {
    bool isHighlighted = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: isHighlighted ? Colors.red[700] : Colors.black87,
                fontWeight: isHighlighted ? FontWeight.bold : FontWeight.w500,
                fontSize: 16,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Patient $patientName"),
        backgroundColor: Colors.white,
        elevation: 2,
      ),
      body: Column(
        children: [
          _buildPatientHeader(),
          if (camerasLoaded) _buildTabBar(),
          Expanded(
            child:
                isLoading || !camerasLoaded
                    ? const Center(child: CircularProgressIndicator())
                    : cameras.isEmpty
                        ? const Center(
                            child: Text(
                              "No cameras found",
                              style: TextStyle(
                                color: Colors.black54,
                                fontSize: 16,
                              ),
                            ),
                          )
                        : TabBarView(
                            controller: _tabController,
                            children:
                                cameras
                                    .map((camera) => _buildCameraTab(camera))
                                    .toList(),
                          ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _tabController?.dispose();
    super.dispose();
  }
}
