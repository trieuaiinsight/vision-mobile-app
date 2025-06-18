import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'patient_records_screen.dart';

class PatientListScreen extends StatefulWidget {
  const PatientListScreen({super.key});

  @override
  State<PatientListScreen> createState() => _PatientListScreenState();
}

class _PatientListScreenState extends State<PatientListScreen> {
  List<Map<String, dynamic>> patients = [];
  List<Map<String, dynamic>> filteredPatients = [];
  bool isLoading = true;
  TextEditingController searchController = TextEditingController();
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    fetchPatients();
    searchController.addListener(_filterPatients);
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  // Filter patients based on search query
  void _filterPatients() {
    final query = searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        filteredPatients = patients;
      } else {
        filteredPatients = patients.where((patient) {
          final name = (patient['name'] ?? '').toString().toLowerCase();
          final code = (patient['code'] ?? '').toString().toLowerCase();
          return name.contains(query) || code.contains(query);
        }).toList();
      }
    });
  }

  // Fetch patients from Supabase and include critical record counts
  Future<void> fetchPatients() async {
    try {
      setState(() {
        isLoading = true;
      });

      final supabase = Supabase.instance.client;
      
      // First, fetch patients with patient_id as text to preserve precision
      final patientsResponse = await supabase
          .from('patients')
          .select('patient_id::text, code, pathology, status, name, avatar, created_at')
          .neq('status', 'discharged')
          .order('created_at', ascending: false);

      final fetchedPatients = List<Map<String, dynamic>>.from(patientsResponse);
      print("✅ Fetched ${fetchedPatients.length} patients");
      
      // Then, fetch critical counts for all patients
      final criticalCountsResponse = await supabase
          .from('patient_records')
          .select('patient_code')
          .eq('status', 'critical')
          .eq('is_checked', false);

      final criticalRecords = List<Map<String, dynamic>>.from(criticalCountsResponse);

      // Count critical records per patient
      Map<String, int> criticalCounts = {};
      for (var record in criticalRecords) {
        final patientCode = record['patient_code'] as String?;
        if (patientCode != null) {
          criticalCounts[patientCode] = (criticalCounts[patientCode] ?? 0) + 1;
        }
      }

      // Merge critical counts into patient data
      for (var patient in fetchedPatients) {
        final patientCode = patient['code'] as String?;
        patient['criticalUnresolvedCount'] = criticalCounts[patientCode] ?? 0;
      }

      setState(() {
        patients = fetchedPatients;
        filteredPatients = fetchedPatients;
        isLoading = false;
      });
    } catch (e) {
      print("❌ Failed to fetch patients: $e");
      setState(() {
        isLoading = false;
      });
      
      if (mounted) {
        _showNetworkErrorDialog("Failed to load patients", "Unable to load patient list: ${e.toString()}");
      }
    }
  }

  // Validate patient by checking from Supabase
  Future<bool> validatePatient(String patientCode) async {
    try {
      final supabase = Supabase.instance.client;
      
      final response = await supabase
          .from('patients')
          .select('patient_id, code, status')
          .eq('code', patientCode)
          .limit(1)
          .maybeSingle();

      if (response == null) {
        return false; // Patient not found
      }

      if (response['status'] != 'active') {
        return false; // Patient not active
      }

      return true;
    } catch (e) {
      print("❌ Failed to validate patient: $e");
      throw e; // Re-throw to handle in calling method
    }
  }

  void _showErrorDialog(String patientCode, String patientDisplayName, String patientName) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          icon: const Icon(
            Icons.error_outline,
            color: Colors.red,
            size: 48,
          ),
          title: const Text(
            "Patient Not Available",
            style: TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Patient ID: $patientCode not found or is not currently available for monitoring.",
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Possible reasons:",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text("• Patient has been discharged"),
                    const Text("• Patient monitoring is inactive"),
                    const Text("• Patient record needs updating"),
                    const Text("• Patient not found or removed from monitoring system"),
                    const Text("• Network connectivity issues"),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("OK"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _showRetryDialog(patientCode, patientDisplayName, patientName);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
              ),
              child: const Text("Retry"),
            ),
          ],
        );
      },
    );
  }

  void _showRetryDialog(String patientCode, String patientDisplayName, String patientName) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Retry Patient Access"),
          content: Text(
            "Would you like to try accessing patient $patientDisplayName ($patientCode) again?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _handlePatientSelection(patientCode, patientDisplayName, patientName);
              },
              child: const Text("Try Again"),
            ),
          ],
        );
      },
    );
  }

  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text("Validating patient..."),
            ],
          ),
        );
      },
    );
  }

  void _handlePatientSelection(String patientCode, String patientDisplayName, String patientName) async {
    // Show loading dialog
    _showLoadingDialog();
    
    try {
      // Validate patient
      final isValid = await validatePatient(patientCode);
      
      // Close loading dialog
      if (mounted) Navigator.of(context).pop();
      
      if (isValid) {
        // Find the selected patient to get full info
        final selectedPatient = patients.firstWhere(
          (p) => p['code'] == patientCode,
          orElse: () => {},
        );
        
        // Patient is valid, navigate to records screen with patient data
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PatientRecordsScreen(
                patientId: selectedPatient['patient_id'],
                patientCode: patientCode,
                patientDisplayName: patientDisplayName,
                patientName: patientName,
                patientAvatar: selectedPatient['avatar'] ?? 'https://via.placeholder.com/150',
                roomNumber: _getRoomNumber(selectedPatient),
                criticalUnresolvedCount: selectedPatient['criticalUnresolvedCount'] ?? 0,
              ),
            ),
          );
        }
      } else {
        // Patient not found or inactive, show error
        if (mounted) {
          _showErrorDialog(patientCode, patientDisplayName, patientName);
        }
      }
    } catch (e) {
      // Close loading dialog
      if (mounted) Navigator.of(context).pop();
      
      // Show network/system error
      if (mounted) {
        _showNetworkErrorDialog("Connection Error", "Unable to verify patient information: ${e.toString()}");
      }
    }
  }

  void _showNetworkErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          icon: const Icon(
            Icons.wifi_off,
            color: Colors.orange,
            size: 48,
          ),
          title: Text(
            title,
            style: const TextStyle(color: Colors.orange),
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                fetchPatients(); // Retry fetching patients
              },
              child: const Text("Retry"),
            ),
          ],
        );
      },
    );
  }

  // Helper method to get patient display name
  String _getPatientDisplayName(Map<String, dynamic> patient) {
    return patient['name'] ?? 'Unknown Patient';
  }

  // Helper method to get room number (placeholder for now)
  String _getRoomNumber(Map<String, dynamic> patient) {
    try {
      // Handle both string and int patient_id safely
      final patientId = patient['patient_id'];
      int idNum;
      
      if (patientId is String) {
        // For large string IDs, use hashCode to generate room number
        idNum = patientId.hashCode.abs();
      } else if (patientId is int) {
        idNum = patientId;
      } else {
        idNum = 0; // Default fallback
      }
      
      return "Room ${(idNum % 500) + 100}"; // Generates Room 100-599
    } catch (e) {
      print("❌ Error generating room number: $e");
      return "Room 100"; // Default fallback
    }
  }

  // Helper method to get status color
  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'active':
        return Colors.green;
      case 'inactive':
        return Colors.red;
      case 'pending':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  void _onBottomNavTap(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  Widget _buildCustomHeader() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Square logo with sparkle icon
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6), // Blue color
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.auto_awesome,
                color: Colors.white,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            // Vision AI text
            const Expanded(
              child: Text(
                "Vision AI",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1F2937),
                  letterSpacing: -0.5,
                ),
              ),
            ),
            // User avatar
            CircleAvatar(
              radius: 22,
              backgroundColor: Colors.grey.shade300,
              backgroundImage: const NetworkImage('https://via.placeholder.com/150'),
              onBackgroundImageError: (_, __) {},
              child: const Icon(
                Icons.person,
                color: Colors.grey,
                size: 24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      margin: const EdgeInsets.all(16),
      child: TextField(
        controller: searchController,
        decoration: InputDecoration(
          hintText: "Search patients",
          hintStyle: TextStyle(color: Colors.grey.shade500),
          prefixIcon: Icon(Icons.search, color: Colors.grey.shade500),
          suffixIcon: IconButton(
            icon: Icon(Icons.filter_list, color: Colors.grey.shade500),
            onPressed: () {
              // Filter functionality placeholder
            },
          ),
          filled: true,
          fillColor: Colors.grey.shade100,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildPatientCard(Map<String, dynamic> patient) {
    final patientId = patient['patient_id'] ?? '';
    final patientCode = patient['code'] ?? 'Unknown';
    final patientName = patient['name'] ?? 'Unknown Patient';
    final pathology = patient['pathology'] ?? '';
    final status = patient['status'] ?? 'unknown';
    final criticalCount = patient['criticalUnresolvedCount'] ?? 0;
    final hasWarnings = criticalCount > 0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: hasWarnings 
              ? const BorderSide(color: Colors.red, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: () {
            _handlePatientSelection(patientCode, _getPatientDisplayName(patient), patientName);
          },
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header with avatar and warning badge
                Row(
                  children: [
                    // Avatar with critical badge
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 25,
                          backgroundColor: Colors.grey.shade200,
                          backgroundImage: patient['avatar'] != null
                              ? NetworkImage(patient['avatar'])
                              : null,
                          onBackgroundImageError: (_, __) {},
                          child: patient['avatar'] == null
                              ? Icon(Icons.person, size: 25, color: Colors.grey.shade600)
                              : null,
                        ),
                        if (hasWarnings)
                          Positioned(
                            top: -2,
                            right: -2,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
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
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    // Patient info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            patientName,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "Code: $patientCode",
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          if (pathology.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              pathology,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                          const SizedBox(height: 2),
                          Text(
                            "52 years old • Nha Trang",
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Warning badge
                    if (hasWarnings)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.red.shade300),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.warning, size: 14, color: Colors.red),
                            const SizedBox(width: 4),
                            Text(
                              "$criticalCount Warning",
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                // 3-column info section
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: hasWarnings 
                        ? Colors.red.shade50 
                        : Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      // Status
                      Expanded(
                        child: Column(
                          children: [
                            Icon(
                              Icons.medical_services,
                              color: hasWarnings ? Colors.red.shade600 : Colors.blue.shade600,
                              size: 20,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              "Status",
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              pathology.isNotEmpty ? pathology : status,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Colors.black87,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      // Room
                      Expanded(
                        child: Column(
                          children: [
                            Icon(
                              Icons.room,
                              color: hasWarnings ? Colors.red.shade600 : Colors.blue.shade600,
                              size: 20,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              "Room",
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _getRoomNumber(patient),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // ID Number
                      Expanded(
                        child: Column(
                          children: [
                            Icon(
                              Icons.badge,
                              color: hasWarnings ? Colors.red.shade600 : Colors.blue.shade600,
                              size: 20,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              "ID Number",
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              patientId.toString(),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Colors.black87,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      body: Column(
        children: [
          _buildCustomHeader(),
          _buildSearchBar(),
          // List heading
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  "List of patients",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: fetchPatients,
                  tooltip: "Refresh",
                ),
              ],
            ),
          ),
          // Patient list
          Expanded(
            child: isLoading
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text("Loading patients..."),
                      ],
                    ),
                  )
                : filteredPatients.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.people_outline,
                              size: 64,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              searchController.text.isNotEmpty 
                                  ? "No patients found for '${searchController.text}'"
                                  : "No patients found",
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              "Pull down to refresh",
                              style: TextStyle(
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: fetchPatients,
                        child: ListView.builder(
                          itemCount: filteredPatients.length,
                          itemBuilder: (context, index) {
                            return _buildPatientCard(filteredPatients[index]);
                          },
                        ),
                      ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        onTap: _onBottomNavTap,
        selectedItemColor: Colors.blue.shade600,
        unselectedItemColor: Colors.grey.shade400,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.chat),
            label: 'Records',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_circle),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
