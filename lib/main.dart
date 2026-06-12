import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_auth/local_auth.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'dart:convert';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
final FlutterTts flutterTts = FlutterTts();

// Global map to track all document uploads across folders
final Map<String, Map<String, dynamic>> globalUploads = {};
final ValueNotifier<int> uploadsNotifier = ValueNotifier(0);

// Global Theme Notifier
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

// --- NOTIFICATION DATA MODEL ---
class AppNotification {
  final String title;
  final String body;
  final DateTime timestamp;
  bool isRead;

  AppNotification({
    required this.title,
    required this.body,
    required this.timestamp,
    this.isRead = false,
  });
}

// Global list to store notifications for the in-app view
final List<AppNotification> globalNotifications = [];
bool isScholarAlertEnabled = true;
bool isBiometricEnabled = false;

final LocalAuthentication auth = LocalAuthentication();

Future<bool> authenticateUser(BuildContext context) async {
  if (!isBiometricEnabled) return true;
  
  try {
    final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
    final bool canAuthenticate = canAuthenticateWithBiometrics || await auth.isDeviceSupported();
    
    if (!canAuthenticate) return true;

    return await auth.authenticate(
      localizedReason: 'Please authenticate to access your Scholar Dashboard',
      options: const AuthenticationOptions(
        stickyAuth: true,
        biometricOnly: false, // Allow fallback to PIN/Pattern if biometrics fail
      ),
    );
  } catch (e) {
    debugPrint("Biometric error: $e");
    return false;
  }
}

// Helper function to play the congratulatory voice message
Future<void> speakCongratulations() async {
  await flutterTts.setLanguage("en-US");
  await flutterTts.setPitch(1.0);
  await flutterTts.speak(
    "Congratulations Scholar! You have successfully passed the examination and are now officially qualified for the scholarship grant. Please wait for your scholarship allowance to be processed. You will automatically receive another notification once the money has been successfully added to your wallet.",
  );
}

const FirebaseOptions _webFirebaseOptions = FirebaseOptions(
  apiKey: "AIzaSyBsLnnK6t7d67fvG3Q-cLQXXWr6NGLemrY",
  authDomain: "student-scholar-app.firebaseapp.com",
  databaseURL: "https://student-scholar-app-default-rtdb.asia-southeast1.firebasedatabase.app",
  projectId: "student-scholar-app",
  storageBucket: "student-scholar-app.firebasestorage.app",
  messagingSenderId: "339061330507",
  appId: "1:339061330507:web:6401015172a614a5c9f3ce",
  measurementId: "G-N8FSMD5Z8N",
);

Future<void> _initializeFirebase() async {
  if (Firebase.apps.isNotEmpty) return;

  if (kIsWeb) {
    await Firebase.initializeApp(options: _webFirebaseOptions);
    return;
  }

  await Firebase.initializeApp();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  await _initializeFirebase();
  await _loadStoredUploads();
  await _initializeBackendServices();
  runApp(const MyApp());
}

Future<void> _loadStoredUploads() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    isBiometricEnabled = prefs.getBool('biometric_enabled') ?? false;
    
    // Load theme preference
    final String? themeStr = prefs.getString('theme_mode');
    if (themeStr != null) {
      themeNotifier.value = ThemeMode.values.firstWhere(
        (m) => m.toString() == themeStr,
        orElse: () => ThemeMode.light,
      );
    }

    final String? encodedData = prefs.getString('persisted_uploads');
    if (encodedData != null) {
      final Map<String, dynamic> decodedMap = json.decode(encodedData);
      globalUploads.clear();
      decodedMap.forEach((key, value) {
        // Convert timestamp string back to DateTime
        if (value is Map<String, dynamic> && value.containsKey('timestamp')) {
          value['timestamp'] = DateTime.parse(value['timestamp']);
        }
        globalUploads[key] = value;
      });
      uploadsNotifier.value = globalUploads.length;
    }
  } catch (e) {
    debugPrint("Error loading uploads: $e");
  }
}

Future<void> _saveUploadsToDisk() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    // Create a copy to avoid modifying the original during serialization
    final Map<String, dynamic> serializableMap = {};
    globalUploads.forEach((key, value) {
      final Map<String, dynamic> item = Map.from(value);
      if (item['timestamp'] is DateTime) {
        item['timestamp'] = (item['timestamp'] as DateTime).toIso8601String();
      }
      serializableMap[key] = item;
    });
    await prefs.setString('persisted_uploads', json.encode(serializableMap));
    uploadsNotifier.value = globalUploads.length;
  } catch (e) {
    debugPrint("Error saving uploads: $e");
  }
}

Future<void> _initializeBackendServices() async {
  try {
    // Initialize a default admin doc if it doesn't exist for management
    final adminDoc = await FirebaseFirestore.instance.collection('users').doc('admin_system').get();
    if (!adminDoc.exists) {
      await FirebaseFirestore.instance.collection('users').doc('admin_system').set({
        'full_name': 'System Administrator',
        'email': 'admin@iskolar.ph',
        'scholar_number': 'ADMIN-001',
        'wallet_balance': 0.0,
        'created_at': FieldValue.serverTimestamp(),
      });
    }
    
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        speakCongratulations();
      },
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'scholar_grant_alerts',
      'Scholarship Alerts',
      description: 'Notifications for scholarship status and exam results',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('scholar_alert'),
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    Future.delayed(const Duration(seconds: 15), () {
      triggerAutomaticNotification(
        title: "Congratulations Scholar!",
        body: "You have successfully passed the examination and are now officially qualified for the scholarship grant. Please wait for your scholarship allowance to be processed. You will automatically receive another notification once the money has been successfully added to your wallet.",
      );
    });
  } catch (e) {
    debugPrint("Backend services error: $e");
  }
}

// Helper function to trigger notification
Future<void> triggerAutomaticNotification({required String title, required String body}) async {
  // 1. Add to in-app notification list
  globalNotifications.insert(0, AppNotification(
    title: title,
    body: body,
    timestamp: DateTime.now(),
  ));

  if (!isScholarAlertEnabled) {
    return;
  }

  // 2. Show push notification
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    'scholar_grant_alerts',
    'Scholarship Alerts',
    channelDescription: 'Notifications for scholarship status and exam results',
    importance: Importance.max,
    priority: Priority.high,
    ticker: 'ticker',
    playSound: true,
    sound: RawResourceAndroidNotificationSound('scholar_alert'),
  );
  
  const NotificationDetails platformChannelSpecifics =
      NotificationDetails(android: androidPlatformChannelSpecifics);
      
  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecond,
    title,
    body,
    platformChannelSpecifics,
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, currentMode, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Scholarship Management',
          themeMode: currentMode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorSchemeSeed: const Color(0xFF4F378A), // Deep Purple
            scaffoldBackgroundColor: const Color(0xFFF3EDFF), // Light Lavender Background
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF3EDFF),
              elevation: 0,
              centerTitle: true,
              titleTextStyle: TextStyle(
                  color: Color(0xFF342361),
                  fontSize: 20,
                  fontWeight: FontWeight.bold),
              iconTheme: IconThemeData(color: Color(0xFF342361)),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xFF4F378A),
            scaffoldBackgroundColor: const Color(0xFF121212),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF121212),
              elevation: 0,
              centerTitle: true,
              titleTextStyle: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold),
              iconTheme: IconThemeData(color: Colors.white),
            ),
            cardColor: const Color(0xFF1E1E1E),
          ),
          home: const SplashScreen(),
        );
      },
    );
  }
}

// --- LOADING / SPLASH SCREEN ---
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _startApp();
  }

  Future<void> _startApp() async {
    // Core services are initialized before runApp in main()
    await Future.delayed(const Duration(milliseconds: 800));
    
    if (mounted) {
      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          // Attempt biometric authentication
          bool isAuthenticated = await authenticateUser(context);
          if (isAuthenticated && mounted) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const MainNavigationWrapper()),
            );
          } else if (!isAuthenticated && mounted) {
            // Fallback to manual login if biometric/PIN fails
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Authentication required. Please log in manually.")),
            );
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const LoginView()),
            );
          }
        } else {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const SignUpView()),
          );
        }
      } catch (e) {
        // If error, still go to SignUp/Login so user can see something
        debugPrint("Splash Screen error: $e");
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const SignUpView()),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF3EDFF),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Simulated Logo based on image
            Column(
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: isDark ? const Color(0xFFBB86FC) : const Color(0xFF4F378A), width: 4),
                      ),
                    ),
                    Icon(Icons.school, size: 70, color: isDark ? const Color(0xFFBB86FC) : const Color(0xFF4F378A)),
                    Positioned(
                      bottom: 10,
                      right: 15,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFFBB86FC) : const Color(0xFF4F378A),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.check, size: 14, color: isDark ? Colors.black : Colors.white),
                      ),
                    )
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  "ISKOLAR",
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    color: isDark ? Colors.white : const Color(0xFF342361),
                  ),
                ),
                Text(
                  "— GRANT —",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    color: isDark ? Colors.white70 : const Color(0xFF4F378A),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 100),
            CircularProgressIndicator(
              color: isDark ? const Color(0xFFBB86FC) : const Color(0xFF4F378A),
              strokeWidth: 4,
            ),
          ],
        ),
      ),
    );
  }
}

// --- LOGIN VIEW ---
class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _isStudentLogin = true;
  final _scholarController = TextEditingController();
  final _passwordController = TextEditingController();

  Future<void> _handleLogin() async {
    if (_scholarController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill in all fields")),
      );
      return;
    }

    if (!_isStudentLogin) {
      // Simple Admin check (You can refine this later with roles in Firestore)
      if (_scholarController.text.trim() != "admin@iskolar.ph" || _passwordController.text.trim() != "admin123") {
         ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Invalid Admin Credentials.")),
        );
        return;
      }
      
      setState(() => _isLoading = true);
      try {
        // Log in with specific admin account if needed, or just bypass for simulation
        // For production, use Firebase Auth roles or specific claims.
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const AdminDashboardView()),
          );
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
      return;
    }

    setState(() => _isLoading = true);

    try {
      final navigator = Navigator.of(context);
      
      String email = _scholarController.text.trim();

      // Kung hindi email ang tinype (walang @), hanapin sa Firestore ang email na ka-match ng Scholar Number
      if (!email.contains('@')) {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .where('scholar_number', isEqualTo: email)
            .limit(1)
            .get();

        if (userDoc.docs.isEmpty) {
          if (mounted) {
            setState(() => _isLoading = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Scholar Number not found.")),
            );
          }
          return;
        }
        email = userDoc.docs.first.get('email');
      }

      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: _passwordController.text.trim(),
      );

      if (mounted) {
        // Authenticate with biometric after successful Firebase login if enabled
        bool isAuthenticated = await authenticateUser(context);
        if (isAuthenticated && mounted) {
          navigator.pushReplacement(
            MaterialPageRoute(builder: (context) => const MainNavigationWrapper()),
          );
        } else if (!isAuthenticated && mounted) {
          // If biometric fails after password login, still allow entry but notify
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Biometric verification skipped.")),
          );
          navigator.pushReplacement(
            MaterialPageRoute(builder: (context) => const MainNavigationWrapper()),
          );
        }
      }
    } on FirebaseAuthException catch (e) {
      String message = "Login failed";
      if (e.code == 'user-not-found') {
        message = "No user found for that Scholar Number.";
      } else if (e.code == 'wrong-password') {
        message = "Wrong password provided.";
      } else if (e.code == 'invalid-credential') {
        message = "Invalid Scholar Number or Password.";
      } else if (e.code == 'invalid-email') {
        message = "The email format is invalid.";
      } else {
        message = e.message ?? "An unexpected error occurred.";
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Header Image Placeholder (Simulating the student image)
            Container(
              width: double.infinity,
              height: 300,
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF3EDFF),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(40),
                  bottomRight: Radius.circular(40),
                ),
              ),
              child: Center(
                child: Icon(Icons.person_pin, size: 180, color: isDark ? const Color(0xFFBB86FC) : const Color(0xFF4F378A)),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Welcome Back!",
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF342361)),
                  ),
                  Text(
                    "Log in to your account",
                    style: TextStyle(color: isDark ? Colors.white70 : Colors.black54, fontSize: 14),
                  ),
                  const SizedBox(height: 32),

                  // Student/Admin Toggle
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => setState(() => _isStudentLogin = true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isStudentLogin ? const Color(0xFF4F378A) : (isDark ? Colors.white10 : const Color(0xFFF3EDFF)),
                            foregroundColor: _isStudentLogin ? Colors.white : (isDark ? Colors.white70 : const Color(0xFF4F378A)),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text("Student Login", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => setState(() => _isStudentLogin = false),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: !_isStudentLogin ? const Color(0xFF4F378A) : (isDark ? Colors.white10 : const Color(0xFFF3EDFF)),
                            foregroundColor: !_isStudentLogin ? Colors.white : (isDark ? Colors.white70 : const Color(0xFF4F378A)),
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text("Admin Login", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),

                  // Scholar Number Field
                  _buildInputField(
                    label: _isStudentLogin ? "Scholar Number" : "Admin ID",
                    hint: _isStudentLogin ? "2026-01001" : "Enter admin ID",
                    icon: _isStudentLogin ? Icons.badge_outlined : Icons.admin_panel_settings_outlined,
                    controller: _scholarController,
                  ),

                  const SizedBox(height: 20),

                  // Password Field
                  _buildInputField(
                    label: "Password",
                    hint: "Enter your password",
                    icon: Icons.lock_outline,
                    isPassword: true,
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    onToggleVisibility: () {
                      setState(() => _obscurePassword = !_obscurePassword);
                    },
                  ),

                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () {},
                      child: Text(
                        "Forgot password?",
                        style: TextStyle(color: isDark ? const Color(0xFFBB86FC) : const Color(0xFF4F378A), fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Login Button
                  ElevatedButton(
                    onPressed: _isLoading ? null : _handleLogin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4F378A),
                      minimumSize: const Size(double.infinity, 60),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    child: _isLoading 
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Login", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  ),

                  const SizedBox(height: 32),

                  Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("Don't have an account? ", style: TextStyle(color: isDark ? Colors.white54 : Colors.black54)),
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const SignUpView()),
                            );
                          },
                          child: Text(
                            "Sign up",
                            style: TextStyle(color: isDark ? const Color(0xFFBB86FC) : const Color(0xFF4F378A), fontWeight: FontWeight.bold),
                          ),
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
    );
  }

  Widget _buildInputField({
    required String label,
    required String hint,
    required IconData icon,
    TextEditingController? controller,
    bool isPassword = false,
    bool obscureText = false,
    VoidCallback? onToggleVisibility,
  }) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : const Color(0xFF1A1A1A))),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 16),
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(icon, color: isDark ? Colors.white38 : Colors.black38, size: 24),
            ),
            suffixIcon: isPassword
              ? Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: isDark ? Colors.white70 : const Color(0xFF342361), size: 24),
                    onPressed: onToggleVisibility,
                  ),
                )
              : null,
            filled: true,
            fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF3EDFF).withValues(alpha: 0.5),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 22),
          ),
        ),
      ],
    );
  }
}

// --- SIGN UP VIEW ---
class SignUpView extends StatefulWidget {
  const SignUpView({super.key});

  @override
  State<SignUpView> createState() => _SignUpViewState();
}

class _SignUpViewState extends State<SignUpView> {
  bool _obscurePassword = true;
  bool _isLoading = false;
  
  String _selectedApplicantType = 'New Applicant';
  String _selectedYearLevel = '1st Year';

  final _nameController = TextEditingController();
  final _scholarController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  void _handleLogin() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LoginView()),
    );
  }

  Future<void> _handleSignUp() async {
    if (_nameController.text.isEmpty || 
        _scholarController.text.isEmpty || 
        _emailController.text.isEmpty || 
        _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please fill in all fields")));
      return;
    }

    if (_passwordController.text != _confirmPasswordController.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Passwords do not match")));
      return;
    }

    setState(() => _isLoading = true);

    try {
      final navigator = Navigator.of(context);
      
      // 1. Create User in Firebase Auth
      UserCredential userCredential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      // 2. Save additional info to Firestore
      await FirebaseFirestore.instance.collection('users').doc(userCredential.user!.uid).set({
        'full_name': _nameController.text.trim(),
        'scholar_number': _scholarController.text.trim(),
        'email': _emailController.text.trim(),
        'applicant_type': _selectedApplicantType,
        'year_level': _selectedYearLevel,
        'wallet_balance': 0.0,
        'course': 'Not Set',
        'created_at': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const MainNavigationWrapper()),
          (route) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? "Registration failed")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent, 
        elevation: 0, 
        iconTheme: IconThemeData(color: isDark ? Colors.white : const Color(0xFF342361))
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Create Account", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: isDark ? Colors.white : const Color(0xFF342361))),
            Text("Join the ISKOLAR community", style: TextStyle(color: isDark ? Colors.white70 : Colors.black54, fontSize: 16)),
            const SizedBox(height: 40),

            _buildInputField(label: "Full Name", hint: "Enter your full name", icon: Icons.person_outline, controller: _nameController),
            const SizedBox(height: 24),
            _buildInputField(label: "Scholar Number", hint: "2026-01001", icon: Icons.badge_outlined, controller: _scholarController),
            const SizedBox(height: 24),
            
            _buildDropdownField(
              label: "Applicant Type",
              value: _selectedApplicantType,
              items: ["New Applicant", "Renewal Applicant"],
              onChanged: (val) => setState(() => _selectedApplicantType = val!),
            ),
            const SizedBox(height: 24),

            _buildDropdownField(
              label: "Year Level",
              value: _selectedYearLevel,
              items: ["1st Year", "2nd Year", "3rd Year", "4th Year"],
              onChanged: (val) => setState(() => _selectedYearLevel = val!),
            ),
            const SizedBox(height: 24),

            _buildInputField(label: "Email Address", hint: "Enter your email", icon: Icons.email_outlined, controller: _emailController),
            const SizedBox(height: 24),
            _buildInputField(
              label: "Password", 
              hint: "Create a password", 
              icon: Icons.lock_outline, 
              isPassword: true, 
              obscureText: _obscurePassword,
              controller: _passwordController,
              onToggleVisibility: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
            const SizedBox(height: 24),
            _buildInputField(
              label: "Confirm Password", 
              hint: "Repeat password", 
              icon: Icons.lock_reset, 
              isPassword: true, 
              obscureText: _obscurePassword, 
              controller: _confirmPasswordController,
              onToggleVisibility: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
            
            const SizedBox(height: 48),

            ElevatedButton(
              onPressed: _isLoading ? null : _handleSignUp,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F378A),
                minimumSize: const Size(double.infinity, 64),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                elevation: 0,
              ),
              child: _isLoading 
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text("Sign Up", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            
            const SizedBox(height: 32),
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Already have an account? ", style: TextStyle(color: isDark ? Colors.white54 : Colors.black54)),
                  GestureDetector(
                    onTap: _handleLogin,
                    child: Text(
                      "Login",
                      style: TextStyle(color: isDark ? const Color(0xFFBB86FC) : const Color(0xFF4F378A), fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : const Color(0xFF1A1A1A))),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF3EDFF).withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFF342361)),
              dropdownColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 16),
              items: items.map((String item) {
                return DropdownMenuItem<String>(
                  value: item,
                  child: Text(item),
                );
              }).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInputField({
    required String label,
    required String hint,
    required IconData icon,
    TextEditingController? controller,
    bool isPassword = false,
    bool obscureText = false,
    VoidCallback? onToggleVisibility,
  }) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : const Color(0xFF1A1A1A))),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 16),
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(icon, color: isDark ? Colors.white38 : Colors.black38, size: 24),
            ),
            suffixIcon: isPassword
              ? Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: isDark ? Colors.white70 : const Color(0xFF342361), size: 24),
                    onPressed: onToggleVisibility,
                  ),
                )
              : null,
            filled: true,
            fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF3EDFF).withValues(alpha: 0.5),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 22),
          ),
        ),
      ],
    );
  }
}

class MainNavigationWrapper extends StatefulWidget {
  const MainNavigationWrapper({super.key});

  @override
  State<MainNavigationWrapper> createState() => _MainNavigationWrapperState();
}

class _MainNavigationWrapperState extends State<MainNavigationWrapper> {
  int _selectedIndex = 0;
  StreamSubscription? _statusSubscription;
  String? _lastStatus;

  final List<Widget> _screens = [
    const HomeView(),
    const ExamStatusView(),
    const RequirementsView(),
    const WithdrawView(),
    const DigitalIDView(),
    const SettingsView(),
  ];

  @override
  void initState() {
    super.initState();
    _listenToStatusChanges();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    super.dispose();
  }

  void _listenToStatusChanges() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _statusSubscription = FirebaseFirestore.instance
        .collection('applications')
        .where('user_id', isEqualTo: user.uid)
        .orderBy('timestamp', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) {
      if (snapshot.docs.isNotEmpty) {
        final data = snapshot.docs.first.data();
        final status = (data['status'] as String?)?.toUpperCase();
        final grantTitle = data['grant_title'] as String? ?? "Scholarship";

        if (_lastStatus != null && _lastStatus != status) {
          _notifyStatusChange(status, grantTitle);
        }
        _lastStatus = status;
      }
    });
  }

  void _notifyStatusChange(String? status, String grantTitle) {
    String title = "Application Update";
    String body = "Your application for $grantTitle status has changed to $status.";

    if (status == "VERIFYING") {
      title = "Documents Under Review";
      body = "Your documents for $grantTitle are now being verified by the scholarship office.";
    } else if (status == "FOR_EXAM") {
      title = "Exam Scheduled!";
      body = "You are now scheduled for the $grantTitle qualifying exam. Check your Exam Dashboard for details.";
    } else if (status == "PASSED") {
      title = "Congratulations!";
      body = "You have passed the $grantTitle qualifying process. You are now officially a scholar!";
      speakCongratulations();
    } else if (status == "FAILED") {
      title = "Application Update";
      body = "We regret to inform you that your application for $grantTitle was not successful at this time.";
    }

    triggerAutomaticNotification(title: title, body: body);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF4F378A),
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10),
        unselectedLabelStyle: const TextStyle(fontSize: 10),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.assignment_turned_in_outlined), activeIcon: Icon(Icons.assignment_turned_in), label: 'Exam'),
          BottomNavigationBarItem(icon: Icon(Icons.description_outlined), activeIcon: Icon(Icons.description), label: 'Docs'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet_outlined), activeIcon: Icon(Icons.account_balance_wallet), label: 'Wallet'),
          BottomNavigationBarItem(icon: Icon(Icons.badge_outlined), activeIcon: Icon(Icons.badge), label: 'ID'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), activeIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

// --- 1. HOME VIEW (Updated with Explore functionality) ---
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  bool _isIncomingFirstYear = true;
  bool _showAllJobs = false;
  bool _showAllFeatured = false;

  void _showProgressModal(Map<String, dynamic>? data, bool isRenewal, String currentStatus) {
    String grantName = data?['active_grant'] ?? (isRenewal ? "Skolar ng Taytay" : "Application");
    
    // Mapping internal status to progress stages
    int stage = 0; // 0 = Preparing/None
    if (isRenewal) {
      if (currentStatus == "VERIFYING") stage = 3;
      if (currentStatus == "PASSED") stage = 4;
    } else {
      if (currentStatus == "PENDING") stage = 1;
      if (currentStatus == "VERIFYING") stage = 2;
      if (currentStatus == "FOR_EXAM") stage = 3;
      if (currentStatus == "PASSED") stage = 4;
    }
    if (currentStatus == "FAILED") stage = -1;

    String getStatusText(int stepIndex) {
      if (stage == -1) return "Pending";
      if (stage > stepIndex) return "Completed";
      if (stage == stepIndex) return "In Progress";
      return "Pending";
    }

    bool isDone(int stepIndex) => stage > stepIndex;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 24),
            Text(isRenewal ? "Renewal: $grantName" : "Progress: $grantName", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Theme.of(context).brightness == Brightness.dark ? Colors.white : const Color(0xFF342361))),
            const Text("Track your current scholarship status", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 32),
            
            if (isRenewal) ...[
              _buildProgressStep("Stage 1: Document Submission", getStatusText(1), isDone(1), true),
              _buildProgressStep("Stage 2: Academic Validation", getStatusText(2), isDone(2), true),
              _buildProgressStep("Stage 3: Verification of Grades", getStatusText(3), isDone(3), true),
              _buildProgressStep("Stage 4: Fund Release", getStatusText(4), isDone(4), false),
            ] else ...[
              _buildProgressStep("Stage 1: Initial Review", getStatusText(1), isDone(1), true),
              _buildProgressStep("Stage 2: Document Verification", getStatusText(2), isDone(2), true),
              _buildProgressStep("Stage 3: Examination Schedule", getStatusText(3), isDone(3), true),
              _buildProgressStep("Stage 4: Final Approval", getStatusText(4), isDone(4), false),
            ],
            
            if (currentStatus == "FAILED") 
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                  child: const Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.redAccent),
                      SizedBox(width: 12),
                      Text("Application not approved. Please contact office.", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              
            const Spacer(),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F378A),
                minimumSize: const Size(double.infinity, 55),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text("Close", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressStep(String title, String status, bool isDone, bool showLine) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDone ? Colors.green : (status == "In Progress" ? const Color(0xFF4F378A) : Colors.grey[200]),
              ),
              child: Icon(isDone ? Icons.check : (status == "In Progress" ? Icons.refresh : Icons.circle), size: 16, color: isDone || status == "In Progress" ? Colors.white : Colors.grey),
            ),
            if (showLine) Container(width: 2, height: 40, color: isDone ? Colors.green : Colors.grey[200]),
          ],
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: status == "Pending" ? Colors.grey : const Color(0xFF342361))),
            Text(status, style: TextStyle(fontSize: 12, color: isDone ? Colors.green : (status == "In Progress" ? const Color(0xFF4F378A) : Colors.grey))),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).snapshots(),
      builder: (context, snapshot) {
        String name = "Scholar";
        String scholarId = "Not Logged In";
        
        if (snapshot.hasData && snapshot.data!.exists) {
          var data = snapshot.data!.data() as Map<String, dynamic>;
          name = data['full_name'] ?? "Scholar";
          scholarId = data['scholar_number'] ?? "";
          bool isRenewal = data['applicant_type'] == "Renewal Applicant";
          String activeGrant = data['active_grant'] ?? (isRenewal ? "Skolar ng Taytay" : "New Application");

          String firstName = name.split(' ')[0];
          String? photoPath = data['profile_photo_path'];

          return Scaffold(
            drawer: const DocumentChecklistDrawer(),
            appBar: AppBar(
              title: const Text("ISKOLAR"),
              leading: Builder(builder: (context) {
                return IconButton(
                  icon: const Icon(Icons.assignment_outlined, color: Color(0xFF4F378A)),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                  tooltip: "Preparation Checklist",
                );
              }),
              actions: [
                IconButton(
                  tooltip: "Notifications",
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const NotificationsListView()),
                    );
                  },
                  icon: Stack(
                    children: [
                      const Icon(Icons.notifications_none),
                      if (globalNotifications.any((n) => !n.isRead))
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                            constraints: const BoxConstraints(minWidth: 8, minHeight: 8),
                          ),
                        )
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 16.0),
                  child: GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const SettingsView()),
                      );
                    },
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: const Color(0xFF4F378A),
                      backgroundImage: photoPath != null ? FileImage(File(photoPath)) : null,
                      child: photoPath == null ? const Icon(Icons.person, color: Colors.white, size: 20) : null,
                    ),
                  ),
                )
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.08),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text("Hello, $firstName! 👋", 
                                  style: TextStyle(
                                    fontSize: 28, 
                                    fontWeight: FontWeight.bold, 
                                    color: Theme.of(context).brightness == Brightness.dark 
                                        ? Colors.white 
                                        : const Color(0xFF342361)
                                  )
                                ),
                                const SizedBox(height: 4),
                                Text("Ready to reach your dreams today?", 
                                  style: TextStyle(
                                    color: Theme.of(context).brightness == Brightness.dark 
                                        ? Colors.white70 
                                        : Colors.black54, 
                                    fontSize: 14, 
                                    fontWeight: FontWeight.w500
                                  )
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: const BoxDecoration(
                              color: Color(0xFFF3EDFF),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.auto_awesome, color: Color(0xFF4F378A), size: 28),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Divider(height: 1, color: Color(0xFFF3EDFF)),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(Icons.badge_outlined, size: 14, color: Theme.of(context).brightness == Brightness.dark ? Colors.white24 : Colors.black26),
                          const SizedBox(width: 8),
                          Text("Scholarship ID: $scholarId", 
                            style: TextStyle(
                              color: Theme.of(context).brightness == Brightness.dark ? Colors.white38 : Colors.black38, 
                              fontSize: 12, 
                              letterSpacing: 0.5
                            )
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 30),

                // Application Status Card
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('applications')
                      .where('user_id', isEqualTo: user?.uid)
                      .orderBy('timestamp', descending: true)
                      .limit(1)
                      .snapshots(),
                  builder: (context, appSnapshot) {
                    return ValueListenableBuilder<int>(
                      valueListenable: uploadsNotifier,
                      builder: (context, docCount, _) {
                        String currentStatus = "NONE";
                        String grantTitle = "No Active Application";
                        double progressValue = 0.0;
                        String progressText = "0/4";
                        String stageLabel = "Select a scholarship to apply";
                        Color statusColor = Colors.grey;

                        if (appSnapshot.hasData && appSnapshot.data!.docs.isNotEmpty) {
                          var appData = appSnapshot.data!.docs.first.data() as Map<String, dynamic>;
                          currentStatus = (appData['status'] ?? "PENDING").toUpperCase();
                          grantTitle = appData['grant_title'] ?? activeGrant;

                          if (currentStatus == "PENDING") {
                            progressValue = 0.25;
                            progressText = "1/4";
                            stageLabel = "Initial Review (Stage 1)";
                            statusColor = const Color(0xFF482F7D);
                          } else if (currentStatus == "VERIFYING") {
                            progressValue = 0.50;
                            progressText = "2/4";
                            stageLabel = "Verification (Stage 2)";
                            statusColor = const Color(0xFF482F7D);
                          } else if (currentStatus == "FOR_EXAM") {
                            progressValue = 0.75;
                            progressText = "3/4";
                            stageLabel = "Examination (Stage 3)";
                            statusColor = const Color(0xFF482F7D);
                          } else if (currentStatus == "PASSED") {
                            progressValue = 1.0;
                            progressText = "4/4";
                            stageLabel = "Completed (Stage 4)";
                            statusColor = Colors.green;
                          } else if (currentStatus == "FAILED") {
                            progressValue = 0.0;
                            progressText = "!";
                            stageLabel = "Application Rejected";
                            statusColor = Colors.redAccent;
                          }
                        } else if (isRenewal) {
                          // Fallback for renewals
                          progressValue = 0.75;
                          progressText = "3/4";
                          stageLabel = "Verification of Grades (Stage 3)";
                          statusColor = Colors.green;
                          currentStatus = "VERIFYING";
                          grantTitle = activeGrant;
                        } else {
                          // Draft/Prep mode
                          if (docCount > 0) {
                            grantTitle = "Preparing Application";
                            progressValue = (docCount / 10).clamp(0.05, 0.20);
                            progressText = "$docCount/10";
                            stageLabel = "Ready to submit once complete";
                            statusColor = const Color(0xFF4F378A);
                          }
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SectionHeader(title: isRenewal ? "Renewal Status" : "Current Application"),
                            const SizedBox(height: 12),
                            GestureDetector(
                              onTap: () {
                                if (currentStatus == "NONE" && docCount == 0) {
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                      title: const Row(
                                        children: [
                                          Icon(Icons.info_outline, color: Color(0xFF4F378A)),
                                          SizedBox(width: 10),
                                          Text("Notice", style: TextStyle(color: Color(0xFF342361))),
                                        ],
                                      ),
                                      content: const Text("You don't have an active application yet. Please scroll down to 'Featured Taytay Grants' and select a scholarship to start your application journey!"),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text("Got it!", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4F378A))),
                                        ),
                                      ],
                                    ),
                                  );
                                } else {
                                  _showProgressModal(data, isRenewal, currentStatus);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: statusColor.withValues(alpha: 0.1)),
                                ),
                                child: Row(
                                  children: [
                                    Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        SizedBox(
                                          width: 50,
                                          height: 50,
                                          child: CircularProgressIndicator(
                                            value: progressValue, 
                                            strokeWidth: 6, 
                                            color: statusColor, 
                                            backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.white12 : Colors.white,
                                          ),
                                        ),
                                        Text(progressText, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                      ],
                                    ),
                                    const SizedBox(width: 20),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(isRenewal ? "Renewal: $grantTitle" : grantTitle, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                          Text(stageLabel, style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black54, fontSize: 12)),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_right, color: statusColor),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),

                const SizedBox(height: 30),

                if (isRenewal) ...[
                  // Renewal-specific Dashboard section
                  const SectionHeader(title: "Maintenance Tracker"),
                  const SizedBox(height: 12),
                  _buildMaintenanceCard("GWA Requirement", "Minimum 2.25", "Your current GWA: 1.75", Colors.green, Icons.trending_up),
                  const SizedBox(height: 12),
                  _buildMaintenanceCard("Required Units", "21 Units", "Completed: 21 Units", Colors.blue, Icons.auto_stories),
                  const SizedBox(height: 30),
                ],

          // Eligibility Filter
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Explore Eligibility:", style: TextStyle(fontWeight: FontWeight.bold)),
              ToggleButtons(
                borderRadius: BorderRadius.circular(12),
                selectedColor: Colors.white,
                fillColor: const Color(0xFF4F378A),
                constraints: const BoxConstraints(minHeight: 32, minWidth: 100),
                isSelected: [_isIncomingFirstYear, !_isIncomingFirstYear],
                onPressed: (index) => setState(() => _isIncomingFirstYear = index == 0),
                children: const [
                  Text("1st Year", style: TextStyle(fontSize: 11)),
                  Text("Current College", style: TextStyle(fontSize: 11)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Featured Section
          SectionHeader(
            title: "Featured Taytay Grants",
            onSeeAll: () => setState(() => _showAllFeatured = !_showAllFeatured),
          ),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('grants').snapshots(),
            builder: (context, snapshot) {
              List<Widget> dynamicCards = [];
              if (snapshot.hasData) {
                for (var doc in snapshot.data!.docs) {
                  var data = doc.data() as Map<String, dynamic>;
                  dynamicCards.add(_buildFeaturedCard(
                    data['title'] ?? "Grant",
                    data['slots'] ?? "Slots",
                    data['benefit'] ?? "Benefit",
                    Color(int.parse(data['color'] ?? "0xFF4F378A")),
                    isVertical: _showAllFeatured,
                    isFirstYear: null, // Dynamic ones shown to all for now
                  ));
                }
              }

              List<Widget> allContent = [...dynamicCards, ..._buildFeaturedContent(user, isVertical: _showAllFeatured)];

              if (!_showAllFeatured) {
                return SizedBox(
                  height: 180,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    children: allContent,
                  ),
                );
              } else {
                return GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.85,
                  children: allContent,
                );
              }
            },
          ),

          const SizedBox(height: 30),

          // Announcements Section
          const SectionHeader(title: "ANNOUNCEMENTS"),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('announcements').orderBy('timestamp', descending: true).snapshots(),
              builder: (context, announcementSnapshot) {
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('applications')
                      .where('user_id', isEqualTo: user?.uid)
                      .orderBy('timestamp', descending: true)
                      .snapshots(),
                  builder: (context, appSnapshot) {
                    List<Widget> cards = [];

                    // 1. Dynamic Admin Announcements from Firestore
                    if (announcementSnapshot.hasData && announcementSnapshot.data!.docs.isNotEmpty) {
                      for (var doc in announcementSnapshot.data!.docs) {
                        var data = doc.data() as Map<String, dynamic>;
                        Timestamp? ts = data['timestamp'] as Timestamp?;
                        String dateStr = ts != null 
                            ? "${ts.toDate().day}/${ts.toDate().month}/${ts.toDate().year}" 
                            : "Today";
                        
                        cards.add(
                          _buildAnnouncementCard(
                            context,
                            data['title'] ?? "Announcement",
                            data['description'] ?? "",
                            dateStr,
                            const Color(0xFF4F378A),
                            data['tag'] ?? "ADMIN",
                          ),
                        );
                      }
                    }

                    // 2. Personal Application Updates (Current Status)
                    if (appSnapshot.hasData && appSnapshot.data!.docs.isNotEmpty) {
                      for (var doc in appSnapshot.data!.docs) {
                        var data = doc.data() as Map<String, dynamic>;
                        String title = data['grant_title'] ?? "Scholarship";
                        String status = data['status'] ?? "PENDING";
                        Timestamp? ts = data['timestamp'] as Timestamp?;
                        String date = ts != null 
                            ? "${ts.toDate().day}/${ts.toDate().month}/${ts.toDate().year}" 
                            : "Processing";

                        Color statusColor = status == "PENDING" ? Colors.amber : 
                                          status == "PASSED" ? Colors.green : Colors.red;

                        String desc = "Your application is currently: $status";
                        if (status == "FOR_EXAM") {
                          desc = "You are scheduled for exam on ${data['exam_date'] ?? 'June 15'}.";
                        } else if (status == "PASSED") {
                          desc = "Congratulations! You are now a qualified scholar.";
                        }

                        cards.add(
                          _buildAnnouncementCard(
                            context,
                            status == "FOR_EXAM" ? "Exam Schedule" : "Status: $title",
                            desc,
                            "Update • $date",
                            statusColor,
                            status == "FOR_EXAM" ? "UPDATE" : "STATUS",
                          ),
                        );
                      }
                    }

                    // 3. Fallback/Default if nothing exists
                    if (cards.isEmpty) {
                      cards.add(
                        _buildAnnouncementCard(
                          context,
                          "Welcome Scholar!",
                          "Check here for official updates and your application status.",
                          "Admin • Today",
                          const Color(0xFF342361),
                          "ADMIN",
                        ),
                      );
                    }

                    return ListView(
                      scrollDirection: Axis.horizontal,
                      children: cards,
                    );
                  },
                );
              },
            ),
          ),

          const SizedBox(height: 30),

          // Vacation Job & Internship List
          SectionHeader(
            title: "Vacation Job Offers", 
            onSeeAll: () => setState(() => _showAllJobs = !_showAllJobs)
          ),
          const SizedBox(height: 12),
          _buildGrantItem("Summer Intern", "Tech Solutions Inc.", "₱15,000 / Month", Colors.blue, Icons.business_center),
          _buildGrantItem("Service Crew", "FastFood Express", "₱500 / Day", Colors.orange, Icons.restaurant),
          _buildGrantItem("Academic Tutor", "Learning Hub", "₱300 / Hour", Colors.green, Icons.menu_book),
          
          if (_showAllJobs) ...[
            _buildGrantItem("Library Assistant", "City Library", "Flexible Hours", Colors.purple, Icons.auto_stories),
            const SizedBox(height: 12),
            _buildGrantItem("Virtual Assistant", "Remote Partners", "Weekly Payout", Colors.teal, Icons.laptop_mac),
            _buildGrantItem("Data Entry Clerk", "BPO Connect", "Project-based Pay", Colors.indigo, Icons.keyboard),
            _buildGrantItem("Summer Camp Staff", "Youth Center", "Free Meals + Stipend", Colors.red, Icons.groups),
            _buildGrantItem("Delivery Rider", "Local Express", "Commission based", Colors.amber, Icons.delivery_dining),
            _buildGrantItem("Promodizer", "Retail World", "Weekly Allowance", Colors.pink, Icons.shopping_bag),
            _buildGrantItem("Social Media Mod", "Digital Agency", "Remote Work", Colors.cyan, Icons.forum),
          ],
        ],
      ),
    );
  }
  return const Center(child: CircularProgressIndicator());
},
);
  }

  Widget _buildMaintenanceCard(String title, String req, String current, Color color, IconData icon) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                Text(req, style: TextStyle(color: isDark ? Colors.white60 : Colors.black54, fontSize: 11)),
                const SizedBox(height: 4),
                Text(current, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFeaturedContent(User? user, {bool isVertical = false}) {
    List<Widget> allCards = [
      _buildFeaturedCard(
        "Iskolar ng Bayan",
        "CHED | SHS Graduates",
        "Free Tuition + Admission",
        const Color(0xFF1A237E),
        isVertical: isVertical,
        isFirstYear: true,
      ),
      _buildFeaturedCard(
        "Iskolar ni Gob",
        "Rizal | Residente 3+ yrs",
        "₱5,000 / Semester",
        const Color(0xFFC62828),
        isVertical: isVertical,
        isFirstYear: false,
      ),
      _buildFeaturedCard(
        "Iskolar ni Juan",
        "DSWD | Tech-voc",
        "Free Tuition + Allowance",
        const Color(0xFF2E7D32),
        isVertical: isVertical,
        isFirstYear: true,
      ),
      _buildFeaturedCard(
        "Iskolar ng Dolores",
        "Brgy. Dolores | College",
        "Educational Assistance",
        const Color(0xFFEF6C00),
        isVertical: isVertical,
        isFirstYear: false,
      ),
      _buildFeaturedCard(
        "Sta. Ana Skolar",
        "Brgy. Sta. Ana | College",
        "Financial Aid per Sem",
        const Color(0xFF6A1B9A),
        isVertical: isVertical,
        isFirstYear: false,
      ),
      _buildFeaturedCard(
        "Skolar ng Muzon",
        "Brgy. Muzon | College",
        "Financial Aid per Sem",
        const Color(0xFF00838F),
        isVertical: isVertical,
        isFirstYear: false,
      ),
      _buildFeaturedCard(
        "Skolar ng Taytay",
        "LGU Taytay | Residents",
        "Financial Aid per Sem",
        const Color(0xFF4F378A),
        isVertical: isVertical,
        isFirstYear: null, // Both
      ),
    ];

    return allCards.where((card) {
      // Logic to filter based on toggle
      final bool? grantIsFirstYear = (card as _FeaturedCardWrapper).isFirstYear;
      if (grantIsFirstYear == null) return true; // Show for both
      return grantIsFirstYear == _isIncomingFirstYear;
    }).toList();
  }

  Widget _buildFeaturedCard(String title, String slots, String benefit, Color color, {bool isVertical = false, bool? isFirstYear}) {
    return _FeaturedCardWrapper(
      isFirstYear: isFirstYear,
      child: Container(
        width: isVertical ? null : 240,
        margin: EdgeInsets.only(right: isVertical ? 0 : 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              slots,
              style: const TextStyle(color: Colors.white70, fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            Text(
              benefit,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ScholarshipDetailView(
                      title: title,
                      color: color,
                    ),
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.9),
                foregroundColor: color,
                elevation: 0,
                minimumSize: const Size(double.infinity, 36),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: EdgeInsets.zero,
              ),
              child: const Text("Apply Now", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrantItem(String title, String target, String benefit, Color color, IconData icon) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ScholarshipDetailView(
              title: title,
              color: color,
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isDark ? Colors.white10 : Colors.grey[200]!),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(target, style: TextStyle(color: isDark ? Colors.white60 : Colors.black54, fontSize: 11)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildAnnouncementCard(BuildContext context, String title, String desc, String date, Color color, [String tag = "NEWS"]) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        if (tag == "UPDATE") {
          // If it's an application update, go to Exam Dashboard
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const ExamStatusView()),
          );
        } else {
          // If it's general news, go to dynamic detail view
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AnnouncementDetailView(
                title: title,
                description: desc,
                date: date,
                tag: tag,
              ),
            ),
          );
        }
      },
      child: Container(
        width: 280,
        margin: const EdgeInsets.only(right: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isDark ? color.withValues(alpha: 0.2) : color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
              child: Text(tag, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
            const Spacer(),
            Text(title, style: TextStyle(color: isDark ? Colors.white : color.withValues(alpha: 0.8), fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(desc, style: TextStyle(color: isDark ? Colors.white70 : Colors.black54, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
            const Spacer(),
            Text(date, style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// Simple wrapper to carry metadata for filtering
class _FeaturedCardWrapper extends StatelessWidget {
  final bool? isFirstYear;
  final Widget child;
  const _FeaturedCardWrapper({required this.isFirstYear, required this.child});
  @override
  Widget build(BuildContext context) => child;
}

// --- 2. EXAM STATUS VIEW ---
class ExamStatusView extends StatelessWidget {
  const ExamStatusView({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text("Exam Dashboard"), elevation: 0),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).snapshots(),
        builder: (context, userSnapshot) {
          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('applications').where('user_id', isEqualTo: user?.uid).orderBy('timestamp', descending: true).limit(1).snapshots(),
            builder: (context, appSnapshot) {
              if (appSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (!appSnapshot.hasData || appSnapshot.data!.docs.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.assignment_outlined, size: 80, color: Colors.grey[400]),
                        const SizedBox(height: 24),
                        Text(
                          "No Active Application",
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.grey[700]),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          "You haven't applied for any scholarship yet. Once you submit an application, your exam details will appear here.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                );
              }

              String name = "Student";
              String scholarId = "N/A";
              String course = "Not Set";
              if (userSnapshot.hasData && userSnapshot.data!.exists) {
                var userData = userSnapshot.data!.data() as Map<String, dynamic>;
                name = userData['full_name'] ?? "Student";
                scholarId = userData['scholar_number'] ?? "N/A";
                course = userData['course'] ?? "Not Set";
              }

              var appData = appSnapshot.data!.docs.first.data() as Map<String, dynamic>;
              String status = (appData['status'] ?? "PENDING").toUpperCase();
              String grantTitle = "${appData['grant_title'] ?? "Scholarship"} Qualifying Exam";
              
              // Dynamic message based on status
              String statusNote = "Your application is under initial review.";
              if (status == "VERIFYING") statusNote = "Documents are being verified by the office.";
              if (status == "FOR_EXAM") statusNote = "You are scheduled for the qualifying examination.";
              if (status == "PASSED") statusNote = "Congratulations! You have passed the qualifying process.";
              if (status == "FAILED") statusNote = "Application was not successful at this time.";

              String examDate = appData['exam_date'] ?? (status == "FOR_EXAM" ? "June 15, 2026" : "TBA (Pending Review)");
              String room = appData['exam_room'] ?? (status == "FOR_EXAM" ? "Room 302" : "--");
              String building = appData['exam_building'] ?? (status == "FOR_EXAM" ? "Main Bldg" : "--");
              String seat = appData['exam_seat'] ?? (status == "FOR_EXAM" ? "24" : "--");
              String time = appData['exam_time'] ?? (status == "FOR_EXAM" ? "8:00 AM" : "TBA");
              String address = appData['exam_address'] ?? "Testing center details will appear after initial review.";
              double? lat = appData['exam_lat'];
              double? lng = appData['exam_lng'];

              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // 1. Exam Status Card
                  _buildDashboardCard(
                    context: context,
                    title: "Application & Exam Status",
                    icon: Icons.assignment_turned_in_outlined,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: status == "PASSED" ? Colors.green.withValues(alpha: 0.1) : (status == "FAILED" ? Colors.red.withValues(alpha: 0.1) : (isDark ? Colors.amber.withValues(alpha: 0.1) : const Color(0xFFFFF8E1))),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                status,
                                style: TextStyle(
                                  color: status == "PASSED" ? Colors.green : (status == "FAILED" ? Colors.red : (isDark ? Colors.amber : const Color(0xFFFBC02D))),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            Text(
                              status == "FOR_EXAM" ? examDate : "Updated: $examDate",
                              style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          grantTitle,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : const Color(0xFF342361),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          statusNote,
                          style: TextStyle(color: isDark ? Colors.white60 : Colors.black54, fontSize: 13),
                        ),
                      ],
                    ),
                  ),

                  if (status == "PASSED")
                    _buildDashboardCard(
                      context: context,
                      title: "Results Summary",
                      icon: Icons.emoji_events_outlined,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                        child: const Row(
                          children: [
                            Icon(Icons.check_circle, color: Colors.green),
                            SizedBox(width: 12),
                            Expanded(child: Text("Qualified for Scholarship Grant!", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
                          ],
                        ),
                      ),
                    )
                  else
                    _buildDashboardCard(
                      context: context,
                      title: "Results Summary",
                      icon: Icons.bar_chart_outlined,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          status == "FAILED" ? "Application not qualified." : "Results are not yet published.",
                          style: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 14),
                        ),
                      ),
                    ),

                  // 3. Exam Details & Location Card
                  _buildDashboardCard(
                    context: context,
                    title: "Exam Details & Location",
                    icon: Icons.location_on_outlined,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildDetailItem(context, "Room", room),
                            _buildDetailItem(context, "Building", building),
                            _buildDetailItem(context, "Seat", seat),
                            _buildDetailItem(context, "Time", time),
                          ],
                        ),
                        const SizedBox(height: 20),
                        const Divider(),
                        const SizedBox(height: 16),
                        Text("Testing Center Address:", style: TextStyle(color: isDark ? Colors.white38 : Colors.black26, fontSize: 11)),
                        const SizedBox(height: 8),
                        Text(
                          address,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: isDark ? Colors.white : const Color(0xFF342361),
                          ),
                        ),
                        const SizedBox(height: 20),
                        
                        // Mini Map Preview
                        GestureDetector(
                          onTap: () async {
                            final String query = lat != null && lng != null ? "$lat,$lng" : Uri.encodeComponent(address);
                            final Uri url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$query');
                            if (!await launchUrl(url)) {
                              debugPrint("Could not launch $url");
                            }
                          },
                          child: Container(
                            height: 150,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white12 : const Color(0xFFF1F3F4), // Map background color
                              borderRadius: BorderRadius.circular(16),
                              image: DecorationImage(
                                image: NetworkImage(lat != null && lng != null 
                                  ? 'https://maps.googleapis.com/maps/api/staticmap?center=$lat,$lng&zoom=16&size=600x300&markers=color:red%7C$lat,$lng&key=YOUR_API_KEY'
                                  : 'https://maps.googleapis.com/maps/api/staticmap?center=${Uri.encodeComponent(address)}&zoom=15&size=600x300&markers=color:red%7C${Uri.encodeComponent(address)}&key=YOUR_API_KEY'), 
                                fit: BoxFit.cover,
                                onError: (e, s) => debugPrint("Map loading error: $e"),
                              ),
                            ),
                            child: Stack(
                              children: [
                                // Realistic Map Background Simulation (Fallback)
                                if (lat == null)
                                  Positioned.fill(
                                    child: Opacity(
                                      opacity: 0.1,
                                      child: Center(
                                        child: Transform.rotate(
                                          angle: 0.2,
                                          child: Icon(Icons.map_outlined, size: 300, color: Colors.black.withValues(alpha: 0.2)),
                                        ),
                                      ),
                                    ),
                                  ),
                                // Simulated Streets (Fallback visual)
                                CustomPaint(
                                  painter: MapGridPainter(),
                                  size: Size.infinite,
                                ),
                                // Gradient Overlay for text readability
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    gradient: LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      colors: [Colors.black.withValues(alpha: 0.4), Colors.transparent],
                                    ),
                                  ),
                                ),
                                // Sharp Location Pin
                                const Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.location_pin, color: Colors.redAccent, size: 42),
                                      SizedBox(height: 4),
                                    ],
                                  ),
                                ),
                                // Bottom Label
                                const Positioned(
                                  bottom: 12,
                                  left: 12,
                                  child: Row(
                                    children: [
                                      Icon(Icons.touch_app, color: Colors.white, size: 14),
                                      SizedBox(width: 6),
                                      Text(
                                        "Tap to view on Google Maps",
                                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                )
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        
                        ElevatedButton.icon(
                          onPressed: () async {
                            final String query = lat != null && lng != null ? "$lat,$lng" : Uri.encodeComponent(address);
                            final Uri url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$query');
                            if (!await launchUrl(url)) {
                              debugPrint("Could not launch $url");
                            }
                          },
                          icon: const Icon(Icons.map_outlined, size: 18),
                          label: const Text("Open Navigation"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4F378A),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(double.infinity, 45),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 4. Scholar Information Card
                  _buildDashboardCard(
                    context: context,
                    title: "Scholar Information",
                    icon: Icons.school_outlined,
                    child: Column(
                      children: [
                        _buildInfoRow(context, "Scholar No", scholarId),
                        const SizedBox(height: 12),
                        _buildInfoRow(context, "Name", name.toLowerCase()),
                        const SizedBox(height: 12),
                        _buildInfoRow(context, "Course", course),
                      ],
                    ),
                  ),

                  // 5. Requirements Status Card
                  _buildDashboardCard(
                    context: context,
                    title: "Requirements Status",
                    icon: Icons.description_outlined,
                    child: Column(
                      children: [
                        _buildDynamicRequirementRow(context, "Report Card", ["Grade 11 Report Card", "Grade 12 Report Card (1st Sem)", "Transcript of Records"]),
                        const SizedBox(height: 12),
                        _buildDynamicRequirementRow(context, "Birth Certificate", ["PSA Birth Certificate"]),
                        const SizedBox(height: 12),
                        _buildDynamicRequirementRow(context, "Income Certificate", ["Certificate of Indigency"]),
                      ],
                    ),
                  ),

                  // 6. Scholarship Qualification Card
                  _buildDashboardCard(
                    context: context,
                    title: "Scholarship Qualification",
                    icon: Icons.emoji_events_outlined,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text("Status:", style: TextStyle(color: isDark ? Colors.white38 : Colors.black26, fontSize: 14)),
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: status == "PASSED" ? Colors.green.withValues(alpha: 0.1) : (isDark ? const Color(0xFF4F378A).withValues(alpha: 0.2) : const Color(0xFFF3EDFF)),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                status == "PASSED" ? "Fully Qualified" : (status == "FAILED" ? "Not Qualified" : "Eligible / Processing"),
                                style: TextStyle(color: status == "PASSED" ? Colors.green : (status == "FAILED" ? Colors.red : (isDark ? Colors.white : const Color(0xFF342361))), fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Icon(status == "PASSED" ? Icons.check_circle : Icons.refresh, size: 18, color: status == "PASSED" ? Colors.green : (isDark ? Colors.white70 : const Color(0xFF342361))),
                            const SizedBox(width: 8),
                            RichText(
                              text: TextSpan(
                                style: TextStyle(color: isDark ? Colors.white70 : const Color(0xFF342361), fontSize: 14),
                                children: [
                                  const TextSpan(text: "Next Step: ", style: TextStyle(fontWeight: FontWeight.bold)),
                                  TextSpan(text: status == "PENDING" ? "Document Verification" : 
                                                 status == "VERIFYING" ? "Examination Schedule" :
                                                 status == "FOR_EXAM" ? "Qualifying Examination" :
                                                 status == "PASSED" ? "Allowance Processing" : "Application Closed"),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildDashboardCard({required BuildContext context, required String title, required IconData icon, required Widget child}) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: isDark ? Colors.white70 : const Color(0xFF342361)),
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: isDark ? Colors.white : const Color(0xFF342361),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }

  Widget _buildDetailItem(BuildContext context, String label, String value) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: isDark ? Colors.white38 : Colors.black26, fontSize: 11)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: isDark ? Colors.white70 : const Color(0xFF342361),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: isDark ? Colors.white38 : Colors.black26, fontSize: 14)),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: isDark ? Colors.white70 : const Color(0xFF342361),
          ),
        ),
      ],
    );
  }

  Widget _buildDynamicRequirementRow(BuildContext context, String label, List<String> vaultKeys) {
    bool isUploaded = vaultKeys.any((key) => globalUploads.containsKey(key));
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Row(
      children: [
        Icon(
          isUploaded ? Icons.check_circle : Icons.hourglass_empty,
          size: 18,
          color: isUploaded ? Colors.green : Colors.orange,
        ),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: isDark ? Colors.white70 : const Color(0xFF342361),
          ),
        ),
        const Spacer(),
        Text(
          isUploaded ? "Completed" : "Pending",
          style: TextStyle(
            color: isUploaded ? Colors.green : Colors.orange,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

// --- 3. ONLINE REQUIREMENTS VIEW ---
class RequirementsView extends StatefulWidget {
  const RequirementsView({super.key});

  @override
  State<RequirementsView> createState() => _RequirementsViewState();
}

class _RequirementsViewState extends State<RequirementsView> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Document Vault"),
      ),
      body: _buildPersonalStorage(),
    );
  }

  Widget _buildPersonalStorage() {
    final recentUploads = globalUploads.entries.toList()
      ..sort((a, b) => (b.value['timestamp'] as DateTime).compareTo(a.value['timestamp'] as DateTime));
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF4F378A).withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF4F378A).withValues(alpha: 0.1)),
          ),
          child: Row(
            children: [
              const Icon(Icons.cloud_done_outlined, color: Color(0xFF4F378A)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Vault Security Active", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text("Your personal documents are encrypted and stored safely.", style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
        Text("Folders", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: isDark ? Colors.white : const Color(0xFF342361))),
        const SizedBox(height: 16),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 1.5,
          children: [
            _buildFolderCard(context, "Certificates", "${globalUploads.values.where((e) => e['folder'] == 'Certificates').length} items", Colors.blue, Icons.workspace_premium),
            _buildFolderCard(context, "IDs", "${globalUploads.values.where((e) => e['folder'] == 'IDs').length} items", Colors.orange, Icons.badge),
            _buildFolderCard(context, "Grades", "${globalUploads.values.where((e) => e['folder'] == 'Grades').length} items", Colors.green, Icons.grade),
            _buildFolderCard(context, "Others", "${globalUploads.values.where((e) => e['folder'] == 'Others').length} items", Colors.grey, Icons.more_horiz),
          ],
        ),
        const SizedBox(height: 30),
        Text("Recent Uploads", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: isDark ? Colors.white : const Color(0xFF342361))),
        const SizedBox(height: 12),
        if (recentUploads.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: Text("No files uploaded yet", style: TextStyle(color: Colors.grey))),
          )
        else
          ...recentUploads.take(5).map((entry) => _buildDocCard(entry.key, entry.value)),
      ],
    );
  }

  Widget _buildFolderCard(BuildContext context, String name, String count, Color color, IconData icon) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => FolderDetailView(folderName: name, color: color, icon: icon)),
        ).then((_) => setState(() {})); // Refresh main view on back
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isDark ? Colors.white10 : Colors.grey[100]!),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const Spacer(),
            Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            Text(count, style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38)),
          ],
        ),
      ),
    );
  }

  Widget _buildDocCard(String title, Map<String, dynamic> file) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor, 
        borderRadius: BorderRadius.circular(16), 
        border: Border.all(color: isDark ? Colors.white10 : Colors.grey[100]!)
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 30),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(file['name'], style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black54)),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() {
                globalUploads.remove(title);
                _saveUploadsToDisk();
              });
            }, 
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent)
          )
        ],
      ),
    );
  }
}

class FolderDetailView extends StatefulWidget {
  final String folderName;
  final Color color;
  final IconData icon;

  const FolderDetailView({super.key, required this.folderName, required this.color, required this.icon});

  @override
  State<FolderDetailView> createState() => _FolderDetailViewState();
}

class _FolderDetailViewState extends State<FolderDetailView> {
  // Mock data for required files per folder
  final Map<String, List<String>> _requiredFiles = {
    "Certificates": ["PSA Birth Certificate", "Certificate of Indigency", "Scholarship Certification"],
    "IDs": ["School ID", "Government ID / Passport"],
    "Grades": ["Grade 11 Report Card", "Grade 12 Report Card (1st Sem)", "Transcript of Records"],
    "Others": ["Good Moral Certificate", "Barangay Clearance"],
  };

  @override
  Widget build(BuildContext context) {
    List<String> requirements = _requiredFiles[widget.folderName] ?? ["General Document"];
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      appBar: AppBar(title: Text(widget.folderName)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Icon(widget.icon, color: widget.color, size: 40),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.folderName, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  Text("Securely Stored", style: TextStyle(color: isDark ? Colors.white38 : Colors.grey)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 32),
          Text("Files Needed", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: isDark ? Colors.white : const Color(0xFF342361))),
          const SizedBox(height: 16),
          
          ...requirements.map((req) => _buildRequirementItem(req, isCustom: false)),
          
          // Show items that are in globalUploads but NOT in the requirements list (Custom uploads)
          ...globalUploads.entries
              .where((e) => e.value['folder'] == widget.folderName && !requirements.contains(e.key))
              .map((entry) => _buildRequirementItem(entry.key, isCustom: true)),
          
          const SizedBox(height: 30),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCustomUploadDialog(),
        label: const Text("Upload New"),
        icon: const Icon(Icons.add_a_photo_outlined),
        backgroundColor: widget.color,
        foregroundColor: Colors.white,
      ),
    );
  }

  void _showCustomUploadDialog() {
    final TextEditingController nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Name your file"),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(hintText: "e.g. My Extra ID"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                Navigator.pop(context);
                _showUploadModal(nameController.text, isCustom: true);
              }
            },
            child: const Text("Next"),
          ),
        ],
      ),
    );
  }

  Widget _buildRequirementItem(String title, {required bool isCustom}) {
    final Map<String, dynamic>? file = globalUploads[title];
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.white10 : Colors.grey[100]!),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.01), blurRadius: 10)],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: file != null ? Colors.green.withValues(alpha: 0.1) : widget.color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              file != null ? Icons.check : Icons.description_outlined, 
              color: file != null ? Colors.green : widget.color, 
              size: 20
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    if (file != null)
                      IconButton(
                        icon: Icon(Icons.edit, size: 14, color: isDark ? Colors.white38 : Colors.grey),
                        onPressed: () => _showRenameDialog(title, isCustom),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ],
                ),
                Text(file != null ? file['name'] : "Pending upload", style: TextStyle(fontSize: 12, color: file != null ? (isDark ? Colors.white70 : Colors.black54) : Colors.redAccent.withValues(alpha: 0.6))),
              ],
            ),
          ),
          if (file == null)
            ElevatedButton(
              onPressed: () => _showUploadModal(title, isCustom: isCustom),
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.color,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(60, 32),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("Upload", style: TextStyle(fontSize: 12)),
            )
          else
            Row(
              children: [
                IconButton(
                  onPressed: () => _showFilePreview(file),
                  icon: const Icon(Icons.visibility_outlined, color: Colors.blue, size: 20),
                  tooltip: "View File",
                ),
                IconButton(
                  onPressed: () => setState(() {
                    globalUploads.remove(title);
                    _saveUploadsToDisk();
                  }), 
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                  tooltip: "Remove",
                ),
              ],
            )
        ],
      ),
    );
  }

  void _showRenameDialog(String oldTitle, bool isCustom) {
    final TextEditingController nameController = TextEditingController(text: oldTitle);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Rename File Label"),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: "New Name"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                setState(() {
                  final data = globalUploads.remove(oldTitle);
                  if (data != null) {
                    globalUploads[nameController.text] = data;
                    _saveUploadsToDisk();
                  }
                });
                Navigator.pop(context);
              }
            },
            child: const Text("Rename"),
          ),
        ],
      ),
    );
  }

  void _showFilePreview(Map<String, dynamic> file) {
    String fileName = file['name'];
    String? filePath = file['path'];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(fileName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Container(
          width: double.maxFinite,
          height: 300,
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: BorderRadius.circular(16),
          ),
          child: filePath != null && (fileName.toLowerCase().endsWith(".jpg") || fileName.toLowerCase().endsWith(".png") || fileName.toLowerCase().endsWith(".jpeg"))
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(
                    File(filePath),
                    fit: BoxFit.contain,
                  ),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      fileName.toLowerCase().endsWith(".pdf") ? Icons.picture_as_pdf : Icons.image,
                      size: 80,
                      color: widget.color.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 20),
                    const Text("Document Preview", style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text("Securely encrypted and stored", style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  void _showUploadModal(String docTitle, {required bool isCustom}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => UploadModal(
        docTitle: docTitle,
        onComplete: (fileData) {
          setState(() {
            fileData['timestamp'] = DateTime.now();
            fileData['folder'] = widget.folderName;
            globalUploads[docTitle] = fileData;
            _saveUploadsToDisk();
          });
        },
      ),
    );
  }
}

class UploadModal extends StatefulWidget {
  final String docTitle;
  final Function(Map<String, dynamic>) onComplete;
  const UploadModal({super.key, required this.docTitle, required this.onComplete});

  @override
  State<UploadModal> createState() => _UploadModalState();
}

class _UploadModalState extends State<UploadModal> {
  bool isUploading = false;
  double progress = 0.0;
  String statusText = "Uploading...";

  void _startUpload(bool fromCamera) async {
    final picker = ImagePicker();
    XFile? pickedFile;
    
    if (fromCamera) {
      pickedFile = await picker.pickImage(source: ImageSource.camera);
    } else {
      // Pick generic file
      FilePickerResult? result = await FilePicker.platform.pickFiles();
      if (result != null) {
        pickedFile = XFile(result.files.single.path!);
      }
    }

    if (pickedFile == null) return;

    setState(() { isUploading = true; });
    for (int i = 0; i <= 100; i += 5) {
      if (!mounted) return;
      setState(() {
        progress = i / 100;
        statusText = "$i% complete";
      });
      await Future.delayed(const Duration(milliseconds: 150));
    }
    widget.onComplete({
      'name': pickedFile.name,
      'path': pickedFile.path,
      'size': "Size calculated"
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 450,
      padding: const EdgeInsets.all(32),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(topLeft: Radius.circular(30), topRight: Radius.circular(30)),
      ),
      child: Column(
        children: [
          Text(isUploading ? "Uploading..." : "Upload File", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text(isUploading ? "It may take a while. Please wait." : "Select and upload your file", style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 30),
          
          if (!isUploading) ...[
            // STEP 1: PICKER UI
            DottedBorderContainer(
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.upload_file_outlined, size: 48, color: Colors.black26),
                    const SizedBox(height: 16),
                    const Text("Select your file to upload", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => _showSourceMenu(),
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F378A), foregroundColor: Colors.white),
                      child: const Text("Browse"),
                    )
                  ],
                ),
              ),
            ),
          ] else ...[
            // STEP 2: PROGRESS UI
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.grey[50], borderRadius: BorderRadius.circular(20)),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.picture_as_pdf, color: Colors.redAccent, size: 40),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.docTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
                            const Text("2.4 MB", style: TextStyle(fontSize: 11, color: Colors.black38)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  LinearProgressIndicator(value: progress, backgroundColor: Colors.grey[200], color: const Color(0xFF4F378A), minHeight: 8),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(statusText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF4F378A))),
                      const Text("140KB/sec", style: TextStyle(fontSize: 11, color: Colors.black38)),
                    ],
                  ),
                ],
              ),
            ),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel", style: TextStyle(color: Colors.black54))),
          ],
          const Spacer(),
          const Text("Powered by Firebase", style: TextStyle(fontSize: 10, color: Colors.black26)),
          const Text("ICCT Colleges", style: TextStyle(fontSize: 10, color: Colors.black26, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  void _showSourceMenu() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sourceItem(Icons.photo_library_outlined, "Gallery", false),
            _sourceItem(Icons.camera_alt_outlined, "Camera", true),
            _sourceItem(Icons.cloud_outlined, "Files", false),
          ],
        ),
      ),
    );
  }

  Widget _sourceItem(IconData icon, String label, bool isCamera) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF4F378A)),
      title: Text(label),
      onTap: () {
        Navigator.pop(context); // Close menu
        _startUpload(isCamera); // Start progress
      },
    );
  }
}

class DottedBorderContainer extends StatelessWidget {
  final Widget child;
  const DottedBorderContainer({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: DottedBorderPainter(color: Colors.grey[300]!), child: child);
  }
}

class DottedBorderPainter extends CustomPainter {
  final Color color;
  DottedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, size.height), const Radius.circular(20)));

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}

class MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.08)
      ..strokeWidth = 3;

    final roadPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 20;

    // Draw main "Sumulong Highway" horizontal road
    canvas.drawLine(Offset(0, size.height * 0.4), Offset(size.width, size.height * 0.5), roadPaint);
    
    // Draw intersecting vertical road
    canvas.drawLine(Offset(size.width * 0.6, 0), Offset(size.width * 0.5, size.height), roadPaint);

    // Draw faint grid for other blocks
    for (double i = 0; i < size.width; i += 50) {
      canvas.drawLine(Offset(i, 0), Offset(i + 10, size.height), paint);
    }
    for (double i = 0; i < size.height; i += 40) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i + 5), paint);
    }

    // Add Road Label
    const textStyle = TextStyle(color: Colors.black38, fontSize: 10, fontWeight: FontWeight.bold);
    final textPainter = TextPainter(
      text: const TextSpan(text: "Sumulong Hwy", style: textStyle),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    canvas.save();
    canvas.translate(size.width * 0.2, size.height * 0.42);
    canvas.rotate(0.1); // Slight tilt to match the image
    textPainter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

// --- 4. WITHDRAW VIEW (3-Part) ---
class WithdrawView extends StatefulWidget {
  const WithdrawView({super.key});

  @override
  State<WithdrawView> createState() => _WithdrawViewState();
}

class _WithdrawViewState extends State<WithdrawView> {
  int _step = 0;
  final _amountController = TextEditingController();
  String _selectedMethod = "";
  final _accountNameController = TextEditingController();
  final _accountNumberController = TextEditingController();
  final _bankNameController = TextEditingController();

  @override
  void dispose() {
    _amountController.dispose();
    _accountNameController.dispose();
    _accountNumberController.dispose();
    _bankNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).snapshots(),
      builder: (context, snapshot) {
        double balance = 0.0;
        if (snapshot.hasData && snapshot.data!.exists) {
          balance = (snapshot.data!.get('wallet_balance') ?? 0.0).toDouble();
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(_step == 0 ? "Withdraw Funds" : _step == 1 ? "Select Method" : "Account Info"),
            leading: _step > 0 ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _step--)) : null,
            actions: _step == 0 ? [
              IconButton(
                icon: const Icon(Icons.history),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const TransactionHistoryView()),
                  );
                },
              )
            ] : null,
          ),
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _buildCurrentStep(balance),
          ),
        );
      }
    );
  }

  Widget _buildCurrentStep(double balance) {
    switch (_step) {
      case 0: return _buildStepA(balance);
      case 1: return _buildStepB();
      case 2: return _buildStepC(balance);
      default: return const SizedBox();
    }
  }

  // PART A: Balance & Amount
  Widget _buildStepA(double balance) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(30),
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF4F378A), Color(0xFF342361)]),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                const Text("Available Balance", style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Text("₱${balance.toStringAsFixed(2)}", style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 40),
          const Text("Enter Amount", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            keyboardType: TextInputType.number,
            onChanged: (val) => setState(() {}), // Trigger rebuild to check amount against balance
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              prefixText: "₱ ",
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF4F378A), width: 2)),
              errorText: (double.tryParse(_amountController.text) ?? 0) > balance ? "Insufficient balance" : null,
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            children: ["500", "1,000", "5,000"].map((val) => ActionChip(
              label: Text("₱$val"),
              onPressed: () => setState(() => _amountController.text = val.replaceAll(",", "")),
              backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.white12 : Colors.grey[100],
            )).toList(),
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: (balance <= 0 || (double.tryParse(_amountController.text) ?? 0.0) <= 0 || (double.tryParse(_amountController.text) ?? 0.0) > balance) 
                ? null 
                : () => setState(() => _step = 1),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F378A),
                disabledBackgroundColor: Colors.grey[300],
                minimumSize: const Size(double.infinity, 55),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16))),
            child: const Text("Withdraw Now",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // PART B: Method Selection
  Widget _buildStepB() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _methodTile("GCash", Icons.account_balance_wallet, Colors.blue),
        _methodTile("Maya", Icons.payments, Colors.green),
        _methodTile("Bank Transfer", Icons.account_balance, Colors.indigo),
      ],
    );
  }

  Widget _methodTile(String name, IconData icon, Color color) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => setState(() { 
        _selectedMethod = name;
        _step = 2; 
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isDark ? Colors.white10 : Colors.grey[200]!),
        ),
        child: Row(
          children: [
            CircleAvatar(backgroundColor: color.withValues(alpha: 0.1), child: Icon(icon, color: color)),
            const SizedBox(width: 20),
            Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  // PART C: Form Fields
  Widget _buildStepC(double balance) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF4F378A).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Color(0xFF4F378A)),
                const SizedBox(width: 12),
                Text(
                  "Method: $_selectedMethod",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF4F378A)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          
          if (_selectedMethod == "Bank Transfer") ...[
            _buildInput("Bank Name", controller: _bankNameController, hint: "e.g. BPI, BDO, Landbank"),
            const SizedBox(height: 16),
          ],
          
          _buildInput("Account Holder Name", controller: _accountNameController, hint: "Enter full name"),
          const SizedBox(height: 16),
          
          _buildInput(
            _selectedMethod == "Bank Transfer" ? "Account Number" : "Mobile Number", 
            controller: _accountNumberController, 
            hint: _selectedMethod == "Bank Transfer" ? "Enter account number" : "e.g. 09123456789",
            keyboardType: TextInputType.number
          ),
          
          const SizedBox(height: 40),
          
          ElevatedButton(
            onPressed: () async {
              final user = FirebaseAuth.instance.currentUser;
              final amount = double.tryParse(_amountController.text) ?? 0.0;

              if (amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Enter a valid amount")));
                return;
              }

              if (amount > balance) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Insufficient balance")));
                return;
              }

              if (_accountNameController.text.isEmpty || _accountNumberController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please fill in all account details")));
                return;
              }

              setState(() => _step = 0); 
              
              // Atomically update balance and record withdrawal
              final userRef = FirebaseFirestore.instance.collection('users').doc(user?.uid);
              
              await FirebaseFirestore.instance.runTransaction((transaction) async {
                final snapshot = await transaction.get(userRef);
                final currentBalance = (snapshot.get('wallet_balance') ?? 0.0).toDouble();
                
                if (currentBalance < amount) {
                  throw Exception("Insufficient funds");
                }
                
                // 1. Subtract from wallet balance
                transaction.update(userRef, {
                  'wallet_balance': currentBalance - amount,
                  'wallet_updated_at': FieldValue.serverTimestamp(),
                });
                
                // 2. Add to withdrawals
                final withdrawalRef = FirebaseFirestore.instance.collection('withdrawals').doc();
                transaction.set(withdrawalRef, {
                  'user_id': user?.uid,
                  'amount': amount,
                  'method': _selectedMethod,
                  'account_name': _accountNameController.text.trim(),
                  'account_number': _accountNumberController.text.trim(),
                  'bank_name': _selectedMethod == "Bank Transfer" ? _bankNameController.text.trim() : _selectedMethod,
                  'timestamp': FieldValue.serverTimestamp(),
                  'status': 'Pending',
                });

                // 3. Log to transactions for unified history
                final transactionRef = FirebaseFirestore.instance.collection('transactions').doc();
                transaction.set(transactionRef, {
                  'user_id': user?.uid,
                  'amount': amount,
                  'type': 'WITHDRAWAL',
                  'method': _selectedMethod,
                  'status': 'PENDING',
                  'title': 'Withdrawal via $_selectedMethod',
                  'timestamp': FieldValue.serverTimestamp(),
                });
              });

              if (mounted) {
                _amountController.clear();
                _accountNameController.clear();
                _accountNumberController.clear();
                _bankNameController.clear();
                
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const TransactionHistoryView()),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text("Withdrawal Request of ₱${amount.toStringAsFixed(2)} Submitted"),
                    backgroundColor: Colors.green,
                  )
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4F378A), 
              minimumSize: const Size(double.infinity, 60), 
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))
            ),
            child: const Text("Confirm & Submit Request", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          )
        ],
      ),
    );
  }

  Widget _buildInput(String label, {TextEditingController? controller, String? hint, TextInputType keyboardType = TextInputType.text}) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26),
            filled: true,
            fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey[100],
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
      ],
    );
  }
}

// --- 5. DIGITAL ID VIEW ---
class DigitalIDView extends StatelessWidget {
  const DigitalIDView({super.key});

  @override
  Widget build(BuildContext context) {
    // Grade 12 = Gold Accent
    const accentColor = Color(0xFFD4AF37);
    final user = FirebaseAuth.instance.currentUser;

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).snapshots(),
      builder: (context, snapshot) {
        String name = "JUAN DELA CRUZ";
        String scholarId = "2026-10045";
        String course = "Grade 12 - STEM";
        String? photoPath;

        if (snapshot.hasData && snapshot.data!.exists) {
          var data = snapshot.data!.data() as Map<String, dynamic>;
          name = (data['full_name'] ?? name).toUpperCase();
          scholarId = data['scholar_number'] ?? scholarId;
          course = "${data['year_level'] ?? 'N/A'} - ${data['course'] ?? 'N/A'}";
          photoPath = data['profile_photo_path'];
        }

        return Scaffold(
          appBar: AppBar(title: const Text("Digital ID")),
          body: Center(
            child: Container(
              width: 300,
              height: 500,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [BoxShadow(color: accentColor.withValues(alpha: 0.2), blurRadius: 30, spreadRadius: 5)],
                border: Border.all(color: accentColor.withValues(alpha: 0.3), width: 2),
              ),
              child: Column(
                children: [
                  const Text("SCHOLARSHIP PORTAL", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: accentColor)),
                  const SizedBox(height: 20),
                  Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.grey[200],
                      shape: BoxShape.circle,
                      border: Border.all(color: accentColor, width: 3),

                      image: photoPath != null ? DecorationImage(image: FileImage(File(photoPath)), fit: BoxFit.cover) : null,
                    ),
                    child: photoPath == null ? const Icon(Icons.person, size: 80, color: Colors.grey) : null,
                  ),
                  const SizedBox(height: 20),
                  Text(name, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : const Color(0xFF342361))),
                  Text(course, style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white38 : Colors.black54)),
                  const SizedBox(height: 10),
                  Text("ID: $scholarId", style: const TextStyle(fontWeight: FontWeight.bold, color: accentColor)),
                  const Spacer(),
                  // Placeholder for QR
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.black12), 
                      borderRadius: BorderRadius.circular(16)
                    ),
                    child: Icon(Icons.qr_code_2, size: 100, color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        );
      }
    );
  }
}



// --- 7. SETTINGS VIEW ---
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool _pushNotifications = true;
  late bool _biometricLogin;

  @override
  void initState() {
    super.initState();
    _biometricLogin = isBiometricEnabled;
  }

  void _showFeatureUnavailable(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("$feature is currently being optimized. Stay tuned!")),
    );
  }

  void _showThemeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Theme Preference"),
        content: ValueListenableBuilder<ThemeMode>(
          valueListenable: themeNotifier,
          builder: (context, currentMode, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _themeOption("Light Mode", ThemeMode.light, currentMode),
                _themeOption("Dark Mode", ThemeMode.dark, currentMode),
                _themeOption("System Default", ThemeMode.system, currentMode),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _themeOption(String label, ThemeMode mode, ThemeMode groupValue) {
    return RadioListTile<ThemeMode>(
      title: Text(label),
      value: mode,
      groupValue: groupValue,
      onChanged: (value) async {
        if (value == null) return;
        final navigator = Navigator.of(context);
        themeNotifier.value = value;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('theme_mode', value.toString());
        if (context.mounted) {
          navigator.pop();
        }
      },
    );
  }

  void _toggleBiometric(bool value) async {
    if (value) {
      // Check if device supports biometrics before trying to enable
      final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final bool canAuthenticate = canAuthenticateWithBiometrics || await auth.isDeviceSupported();

      if (!canAuthenticate) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Biometric authentication is not supported on this device.")),
          );
        }
        return;
      }

      bool authenticated = false;
      try {
        authenticated = await auth.authenticate(
          localizedReason: 'Confirm your identity to enable biometric login',
          options: const AuthenticationOptions(
            stickyAuth: true,
            biometricOnly: false,
          ),
        );
      } catch (e) {
        debugPrint("Biometric enrollment error: $e");
      }

      if (authenticated) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('biometric_enabled', true);
        setState(() {
          isBiometricEnabled = true;
          _biometricLogin = true;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Biometric login enabled!")),
          );
        }
      } else {
        setState(() {
          _biometricLogin = false;
        });
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('biometric_enabled', false);
      setState(() {
        isBiometricEnabled = false;
        _biometricLogin = false;
      });
    }
  }

  Future<void> _changeProfilePicture() async {
    final picker = ImagePicker();
    
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20))),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Update Profile Picture", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text("Requirement: Please use a real photo of your face. Avatars or animated photos are not allowed.", 
              style: TextStyle(color: Colors.redAccent, fontSize: 12), textAlign: TextAlign.center),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildPickerOption(Icons.camera_alt, "Camera", () async {
                  Navigator.pop(context);
                  final XFile? image = await picker.pickImage(source: ImageSource.camera);
                  if (image != null) _updateProfilePhoto(image.path);
                }),
                _buildPickerOption(Icons.photo_library, "Gallery", () async {
                  Navigator.pop(context);
                  final XFile? image = await picker.pickImage(source: ImageSource.gallery);
                  if (image != null) _updateProfilePhoto(image.path);
                }),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildPickerOption(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFFF3EDFF), shape: BoxShape.circle),
            child: Icon(icon, color: const Color(0xFF4F378A), size: 30),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Future<void> _updateProfilePhoto(String path) async {
    final user = FirebaseAuth.instance.currentUser;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    
    // 1. Show validation status
    scaffoldMessenger.showSnackBar(
      const SnackBar(content: Text("Validating profile photo..."), duration: Duration(seconds: 2)),
    );

    // 2. Perform Face Detection
    final InputImage inputImage = InputImage.fromFilePath(path);
    final faceDetector = FaceDetector(options: FaceDetectorOptions(
      enableContours: false,
      enableClassification: false,
    ));

    try {
      final List<Face> faces = await faceDetector.processImage(inputImage);
      if (!context.mounted) return;
      await faceDetector.close();
      if (!context.mounted) return;

      if (faces.isEmpty) {
        // NO FACE DETECTED
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red),
                  SizedBox(width: 10),
                  Text("Invalid Photo"),
                ],
              ),
              content: const Text("Face not detected. Please upload a clear photo of your face. Avatars, objects, or scenery are not allowed for scholarship security."),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Try Again"),
                ),
              ],
            ),
          );
        return;
      }

      // FACE DETECTED -> Proceed with update
      // In a real app, you would upload to Firebase Storage first.
      // For this simulation, we'll save the local path to Firestore.
      await FirebaseFirestore.instance.collection('users').doc(user?.uid).update({
        'profile_photo_path': path,
      });
      
      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text("Profile photo verified and updated successfully!")),
        );
      }
    } catch (e) {
      debugPrint("Face detection error: $e");
      if (context.mounted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text("Error validating photo. Please try again.")),
        );
      }
    }
  }

  Future<void> _editProfile(Map<String, dynamic> data) async {
    final nameController = TextEditingController(text: data['full_name']);
    final courseController = TextEditingController(text: data['course'] ?? "");
    final scholarNumController = TextEditingController(text: data['scholar_number'] ?? "");

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Edit Personal Information"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameController, decoration: const InputDecoration(labelText: "Full Name")),
              const SizedBox(height: 16),
              TextField(controller: courseController, decoration: const InputDecoration(labelText: "Course")),
              const SizedBox(height: 16),
              TextField(controller: scholarNumController, decoration: const InputDecoration(labelText: "Scholar Number")),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              final user = FirebaseAuth.instance.currentUser;
              final navigator = Navigator.of(context);
              await FirebaseFirestore.instance.collection('users').doc(user?.uid).update({
                'full_name': nameController.text.trim(),
                'course': courseController.text.trim(),
                'scholar_number': scholarNumController.text.trim(),
              });
              if (mounted) navigator.pop();
            },
            child: const Text("Save Changes"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).snapshots(),
      builder: (context, snapshot) {
        String name = "Juan Dela Cruz";
        String email = user?.email ?? "student@scholar.app";
        String? photoPath;
        Map<String, dynamic> data = {};

        if (snapshot.hasData && snapshot.data!.exists) {
          data = snapshot.data!.data() as Map<String, dynamic>;
          name = data['full_name'] ?? name;
          photoPath = data['profile_photo_path'];
        }

        return Scaffold(
          appBar: AppBar(title: const Text("Settings")),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 20),
            children: [
              Center(
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _changeProfilePicture,
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CircleAvatar(
                            radius: 50,
                            backgroundColor: const Color(0xFF4F378A),
                            backgroundImage: photoPath != null ? FileImage(File(photoPath)) : null,
                            child: photoPath == null ? const Icon(Icons.person, size: 60, color: Colors.white) : null,
                          ),
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(color: Color(0xFF342361), shape: BoxShape.circle),
                            child: const Icon(Icons.camera_alt, size: 18, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    Text(email, style: const TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              _buildSettingItem("Edit Profile", Icons.person_outline, onTap: () => _editProfile(data)),
              _buildToggleItem("Notification Push", _pushNotifications, (v) => setState(() => _pushNotifications = v)),
              _buildToggleItem("Scholar Alert Sound", isScholarAlertEnabled, (v) {
                setState(() {
                  isScholarAlertEnabled = v;
                });
              }),
              _buildSettingItem("Theme Preferences", Icons.palette_outlined, onTap: _showThemeDialog),
              const Divider(indent: 20, endIndent: 20),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text("SECURITY", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              _buildToggleItem("Biometric Log-in", _biometricLogin, _toggleBiometric),
              _buildSettingItem("Change Password", Icons.lock_outline, onTap: () => _showFeatureUnavailable("Password recovery")),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextButton(
                  onPressed: () async {
                    try {
                      await FirebaseAuth.instance.signOut();
                      if (context.mounted) {
                        Navigator.pushAndRemoveUntil(
                          context,
                          MaterialPageRoute(builder: (context) => const LoginView()),
                          (route) => false,
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("Error logging out: $e")),
                        );
                      }
                    }
                  },
                  style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                  child: const Text("Log Out"),
                ),
              ),
            ],
          ),
        );
      }
    );
  }

  Widget _buildSettingItem(String title, IconData icon, {VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF4F378A)),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }

  Widget _buildToggleItem(String title, bool val, [ValueChanged<bool>? onChanged]) {
    return SwitchListTile(
      value: val,
      onChanged: onChanged ?? (v) {},
      secondary: Icon(
        title.contains("Biometric") ? Icons.fingerprint : 
        title.contains("Alert") ? Icons.volume_up_outlined : Icons.notifications_active_outlined, 
        color: const Color(0xFF4F378A)
      ),
      title: Text(title),
      activeThumbColor: const Color(0xFF4F378A),
    );
  }
}

class DocumentChecklistDrawer extends StatefulWidget {
  const DocumentChecklistDrawer({super.key});

  @override
  State<DocumentChecklistDrawer> createState() => _DocumentChecklistDrawerState();
}

class _DocumentChecklistDrawerState extends State<DocumentChecklistDrawer> {
  // Simple local state for the session. For persistence, use SharedPreferences.
  final Map<String, bool> _checkedItems = {
    "ITR of Parents / Affidavit": false,
    "Certificate of Indigency": false,
    "Certified True Copy of Grades": false,
    "GWA Certification": false,
    "Good Moral Certificate": false,
    "PSA Birth Certificate": false,
    "Voter's Certification": false,
  };

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Colors.white,
      child: Column(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF4F378A), Color(0xFF342361)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.fact_check, color: Colors.white, size: 40),
                  SizedBox(height: 12),
                  Text(
                    "Requirement Guide",
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "Track your documents",
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 20, 20, 10),
                  child: Text(
                    "PREPARATION CHECKLIST",
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1),
                  ),
                ),
                ..._checkedItems.keys.map((title) => _buildCheckItem(title)),
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3EDFF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, size: 16, color: Color(0xFF4F378A)),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            "Tick these off as you prepare your physical copies.",
                            style: TextStyle(fontSize: 11, color: Color(0xFF4F378A)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                backgroundColor: const Color(0xFF4F378A),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text("Got it!", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildCheckItem(String title) {
    return CheckboxListTile(
      value: _checkedItems[title],
      onChanged: (v) {
        setState(() {
          _checkedItems[title] = v ?? false;
        });
      },
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: _checkedItems[title]! ? FontWeight.bold : FontWeight.normal,
          color: _checkedItems[title]! ? const Color(0xFF4F378A) : Colors.black87,
          decoration: _checkedItems[title]! ? TextDecoration.lineThrough : null,
        ),
      ),
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: const Color(0xFF4F378A),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    );
  }
}

// --- ANNOUNCEMENT DETAIL VIEW ---
class AnnouncementDetailView extends StatelessWidget {
  final String title;
  final String description;
  final String date;
  final String tag;

  const AnnouncementDetailView({
    super.key,
    this.title = "Scholarship Update",
    this.description = "More details about this announcement will be posted soon.",
    this.date = "Today",
    this.tag = "NEWS",
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Announcement"),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Image Placeholder
            Container(
              width: double.infinity,
              height: 200,
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 120,
                    height: 120,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const Icon(Icons.school, size: 80, color: Color(0xFF1E1B4B)),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(tag, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),

                  const SizedBox(height: 20),
                  Text(
                    title,
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF342361)),
                  ),

                  const SizedBox(height: 24),

                  _buildAnnouncementInfoRow(Icons.calendar_today_outlined, date),
                  _buildAnnouncementInfoRow(Icons.access_time, "Office Hours (8:00 AM - 5:00 PM)"),
                  _buildAnnouncementInfoRow(Icons.location_on_outlined, "Scholarship Office / Online"),

                  const SizedBox(height: 32),

                  Text(
                    description,
                    style: const TextStyle(color: Colors.black87, height: 1.6, fontSize: 15),
                  ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnnouncementInfoRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.black54),
          const SizedBox(width: 16),
          Text(text, style: const TextStyle(fontSize: 16, color: Colors.black87)),
        ],
      ),
    );
  }
}

// --- NEW: IN-APP NOTIFICATIONS LIST VIEW ---
class NotificationsListView extends StatefulWidget {
  const NotificationsListView({super.key});

  @override
  State<NotificationsListView> createState() => _NotificationsListViewState();
}

class _NotificationsListViewState extends State<NotificationsListView> {
  @override
  void initState() {
    super.initState();
    // Mark all as read when opening the screen
    for (var notification in globalNotifications) {
      notification.isRead = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Notifications"),
        actions: [
          TextButton(
            onPressed: () => setState(() => globalNotifications.clear()),
            child: const Text("Clear All", style: TextStyle(color: Color(0xFF4F378A))),
          )
        ],
      ),
      body: globalNotifications.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_off_outlined, size: 80, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  const Text("No notifications yet", style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: globalNotifications.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final notification = globalNotifications[index];
                final bool isDark = Theme.of(context).brightness == Brightness.dark;
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4F378A).withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.celebration, color: Color(0xFF4F378A), size: 20),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              notification.title,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              notification.body,
                              style: const TextStyle(color: Colors.black87, fontSize: 13, height: 1.4),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              "${notification.timestamp.hour}:${notification.timestamp.minute.toString().padLeft(2, '0')} ${notification.timestamp.hour >= 12 ? 'PM' : 'AM'}",
                              style: const TextStyle(color: Colors.black38, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

// --- TRANSACTION HISTORY VIEW ---
class TransactionHistoryView extends StatelessWidget {
  const TransactionHistoryView({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text("Transaction History")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('transactions')
            .where('user_id', isEqualTo: user?.uid)
            .orderBy('timestamp', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 80, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  const Text("No transactions yet", style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          final docs = snapshot.data!.docs;

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              final bool isDark = Theme.of(context).brightness == Brightness.dark;
              final amount = (data['amount'] ?? 0.0).toDouble();
              final String type = (data['type'] ?? 'WITHDRAWAL').toUpperCase();
              final status = data['status'] ?? 'Pending';
              final title = data['title'] ?? (type == 'WITHDRAWAL' ? 'Withdrawal Request' : 'Grant Received');
              final timestamp = data['timestamp'] as Timestamp?;
              final dateStr = timestamp != null
                  ? "${timestamp.toDate().day}/${timestamp.toDate().month}/${timestamp.toDate().year}"
                  : "Today";

              final bool isCredit = type == 'GRANT' || type == 'DEPOSIT';
              final Color iconColor = isCredit ? Colors.green : Colors.redAccent;
              final IconData iconData = isCredit ? Icons.account_balance_wallet_outlined : Icons.outbound;

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: isDark ? Colors.white10 : Colors.grey[100]!),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(iconData, color: iconColor, size: 20),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                          Text(dateStr, style: const TextStyle(color: Colors.black38, fontSize: 11)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text("${isCredit ? '+' : '-'}₱${amount.toStringAsFixed(2)}",
                            style: TextStyle(fontWeight: FontWeight.bold, color: iconColor)),
                        Text(status,
                            style: TextStyle(
                                color: status == 'Completed' || status == 'PASSED' ? Colors.green : (status == 'Rejected' ? Colors.red : Colors.orange),
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// --- ADMIN CONTROL PANEL ---
bool get _adminFirebaseReady => Firebase.apps.isNotEmpty;

final List<Map<String, dynamic>> _previewScholars = [
  {
    'full_name': 'Juan Dela Cruz',
    'email': 'juan@example.com',
    'scholar_number': '2026-01001',
    'year_level': '1st Year',
    'applicant_type': 'New Applicant',
    'course': 'BS Information Technology',
    'wallet_balance': 2500.0,
  },
  {
    'full_name': 'Maria Clara',
    'email': 'maria@example.com',
    'scholar_number': '2026-01002',
    'year_level': '2nd Year',
    'applicant_type': 'Renewal Applicant',
    'course': 'BS Education',
    'wallet_balance': 3200.0,
  },
  {
    'full_name': 'Pedro Santos',
    'email': 'pedro@example.com',
    'scholar_number': '2026-01003',
    'year_level': 'Grade 12',
    'applicant_type': 'New Applicant',
    'course': 'STEM',
    'wallet_balance': 1800.0,
  },
];

final List<Map<String, dynamic>> _previewApplications = [
  {
    'grant_title': 'Skolar ng Taytay',
    'user_id': 'preview-user-001',
    'status': 'PENDING',
  },
  {
    'grant_title': 'GT REAP STEM',
    'user_id': 'preview-user-002',
    'status': 'PASSED',
  },
];

final List<Map<String, dynamic>> _previewWithdrawals = [
  {
    'amount': 1500.0,
    'method': 'GCash',
    'status': 'Pending',
  },
  {
    'amount': 800.0,
    'method': 'Cash Pickup',
    'status': 'Completed',
  },
];

final List<Map<String, dynamic>> _previewGrants = [
  {
    'title': 'Skolar ng Taytay',
    'slots': '100 Slots',
    'benefit': '₱15,000 / Semester',
  },
  {
    'title': 'GT REAP STEM',
    'slots': '50 Slots',
    'benefit': '₱10,000 / Semester',
  },
];

final List<Map<String, dynamic>> _adminRecentActivities = [
  {
    'title': 'Juan Dela Cruz submitted a new application',
    'time': '2 minutes ago',
    'icon': Icons.person_add_alt_1_outlined,
    'color': Colors.blue,
  },
  {
    'title': 'GCash Payout processed for Maria Clara',
    'time': '1 hour ago',
    'icon': Icons.account_balance_wallet_outlined,
    'color': Colors.green,
  },
  {
    'title': "New Grant 'GT REAP STEM' published",
    'time': '3 hours ago',
    'icon': Icons.campaign_outlined,
    'color': Colors.purple,
  },
  {
    'title': 'Pedro Santos was added to the scholars list',
    'time': 'Yesterday',
    'icon': Icons.people_outline,
    'color': Colors.indigo,
  },
  {
    'title': 'Admin reviewed a pending withdrawal request',
    'time': 'Yesterday',
    'icon': Icons.fact_check_outlined,
    'color': Colors.orange,
  },
];

DateTime? _activityDate(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

String _formatActivityTime(DateTime value) {
  final diff = DateTime.now().difference(value);
  if (diff.inSeconds < 60) return "Just now";
  if (diff.inMinutes < 60) return "${diff.inMinutes} minute${diff.inMinutes == 1 ? '' : 's'} ago";
  if (diff.inHours < 24) return "${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago";
  if (diff.inDays < 7) return "${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago";
  return "${value.month}/${value.day}/${value.year}";
}

String _formatDateTimeValue(dynamic value) {
  final date = _activityDate(value);
  if (date == null) return "Not available";
  final hour = date.hour == 0 ? 12 : (date.hour > 12 ? date.hour - 12 : date.hour);
  final minute = date.minute.toString().padLeft(2, '0');
  final period = date.hour >= 12 ? 'PM' : 'AM';
  return "${date.month}/${date.day}/${date.year} $hour:$minute $period";
}

Widget _buildStatusBadge(String status) {
  Color color;
  switch (status.toUpperCase()) {
    case 'PASSED':
      color = Colors.green;
      break;
    case 'FAILED':
      color = Colors.red;
      break;
    case 'FOR_EXAM':
      color = Colors.purple;
      break;
    case 'VERIFYING':
      color = Colors.blue;
      break;
    case 'PENDING':
      color = Colors.orange;
      break;
    default:
      color = Colors.grey;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Text(
      status,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
    ),
  );
}

Widget _buildQualificationsSummary(Map<String, dynamic> data) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        "Applicant: ${data['applicant_name'] ?? 'Unknown'}",
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF342361)),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          _buildMiniInfo("GWA: ${data['gwa'] ?? 'N/A'}"),
          const SizedBox(width: 8),
          _buildMiniInfo("Income: ${data['income'] ?? 'N/A'}"),
        ],
      ),
    ],
  );
}

Widget _buildMiniInfo(String text) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xFFF3EDFF),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 10, color: Color(0xFF4F378A), fontWeight: FontWeight.bold),
    ),
  );
}

List<Map<String, dynamic>> _buildAdminActivityItems({
  required List<QueryDocumentSnapshot> userDocs,
  required List<QueryDocumentSnapshot> applicationDocs,
  required List<QueryDocumentSnapshot> withdrawalDocs,
  required List<QueryDocumentSnapshot> grantDocs,
}) {
  final activities = <Map<String, dynamic>>[];
  final userNames = <String, String>{};

  for (final doc in userDocs) {
    final data = doc.data() as Map<String, dynamic>;
    final fullName = (data['full_name'] ?? 'A scholar').toString();
    userNames[doc.id] = fullName;

    final createdAt = _activityDate(data['created_at']);
    if (createdAt != null && doc.id != 'admin_system') {
      activities.add({
        'title': '$fullName was added to the scholars list',
        'time': _formatActivityTime(createdAt),
        'sortTime': createdAt,
        'icon': Icons.people_outline,
        'color': Colors.indigo,
      });
    }

    final walletUpdatedAt = _activityDate(data['wallet_updated_at']);
    if (walletUpdatedAt != null) {
      activities.add({
        'title': 'Wallet balance updated for $fullName',
        'time': _formatActivityTime(walletUpdatedAt),
        'sortTime': walletUpdatedAt,
        'icon': Icons.account_balance_wallet_outlined,
        'color': Colors.teal,
      });
    }
  }

  for (final doc in applicationDocs) {
    final data = doc.data() as Map<String, dynamic>;
    final applicant = userNames[data['user_id']] ?? 'A scholar';
    final submittedAt = _activityDate(data['timestamp']);
    final reviewedAt = _activityDate(data['reviewed_at']);
    final status = (data['status'] ?? 'PENDING').toString();

    if (submittedAt != null) {
      activities.add({
        'title': '$applicant submitted a new application',
        'time': _formatActivityTime(submittedAt),
        'sortTime': submittedAt,
        'icon': Icons.person_add_alt_1_outlined,
        'color': Colors.blue,
      });
    }

    if (reviewedAt != null && status == 'PASSED') {
      activities.add({
        'title': 'Application approved for $applicant',
        'time': _formatActivityTime(reviewedAt),
        'sortTime': reviewedAt,
        'icon': Icons.verified_outlined,
        'color': Colors.green,
      });
    } else if (reviewedAt != null && status == 'FAILED') {
      activities.add({
        'title': 'Application rejected for $applicant',
        'time': _formatActivityTime(reviewedAt),
        'sortTime': reviewedAt,
        'icon': Icons.cancel_outlined,
        'color': Colors.redAccent,
      });
    }
  }

  for (final doc in withdrawalDocs) {
    final data = doc.data() as Map<String, dynamic>;
    final userName = userNames[data['user_id']] ?? 'A scholar';
    final method = (data['method'] ?? 'Payout').toString();
    final submittedAt = _activityDate(data['timestamp']);
    final processedAt = _activityDate(data['processed_at']);
    final status = (data['status'] ?? 'Pending').toString();

    if (submittedAt != null) {
      activities.add({
        'title': '$userName requested a payout via $method',
        'time': _formatActivityTime(submittedAt),
        'sortTime': submittedAt,
        'icon': Icons.payments_outlined,
        'color': Colors.orange,
      });
    }

    if (processedAt != null && status == 'Completed') {
      activities.add({
        'title': '$method payout processed for $userName',
        'time': _formatActivityTime(processedAt),
        'sortTime': processedAt,
        'icon': Icons.account_balance_wallet_outlined,
        'color': Colors.green,
      });
    } else if (processedAt != null && status == 'Rejected') {
      activities.add({
        'title': '$method payout rejected for $userName',
        'time': _formatActivityTime(processedAt),
        'sortTime': processedAt,
        'icon': Icons.money_off_csred_outlined,
        'color': Colors.redAccent,
      });
    }
  }

  for (final doc in grantDocs) {
    final data = doc.data() as Map<String, dynamic>;
    final createdAt = _activityDate(data['created_at']);
    final title = (data['title'] ?? 'New Grant').toString();
    if (createdAt != null) {
      activities.add({
        'title': "New Grant '$title' published",
        'time': _formatActivityTime(createdAt),
        'sortTime': createdAt,
        'icon': Icons.campaign_outlined,
        'color': Colors.purple,
      });
    }
  }

  activities.sort((a, b) {
    final aTime = a['sortTime'] as DateTime?;
    final bTime = b['sortTime'] as DateTime?;
    if (aTime == null && bTime == null) return 0;
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    return bTime.compareTo(aTime);
  });

  return activities;
}

class AdminRecentActivityFeed extends StatelessWidget {
  final int? limit;
  const AdminRecentActivityFeed({super.key, this.limit});

  @override
  Widget build(BuildContext context) {
    if (!_adminFirebaseReady) {
      final items = limit == null
          ? _adminRecentActivities
          : _adminRecentActivities.take(limit!).toList();
      return Column(
        children: items
            .map(
              (activity) => _buildAdminActivityEntry(
                context,
                activity['title'] as String,
                activity['time'] as String,
                activity['icon'] as IconData,
                activity['color'] as Color,
              ),
            )
            .toList(),
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('users').snapshots(),
      builder: (context, userSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('applications').snapshots(),
          builder: (context, appSnap) {
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('withdrawals').snapshots(),
              builder: (context, withdrawalSnap) {
                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance.collection('grants').snapshots(),
                  builder: (context, grantSnap) {
                    final userDocs = userSnap.data?.docs ?? [];
                    final applicationDocs = appSnap.data?.docs ?? [];
                    final withdrawalDocs = withdrawalSnap.data?.docs ?? [];
                    final grantDocs = grantSnap.data?.docs ?? [];

                    if (!userSnap.hasData &&
                        !appSnap.hasData &&
                        !withdrawalSnap.hasData &&
                        !grantSnap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    final activities = _buildAdminActivityItems(
                      userDocs: userDocs,
                      applicationDocs: applicationDocs,
                      withdrawalDocs: withdrawalDocs,
                      grantDocs: grantDocs,
                    );

                    if (activities.isEmpty) {
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Text(
                          "No recent activity yet.",
                          style: TextStyle(color: Colors.grey),
                        ),
                      );
                    }

                    final visibleItems =
                        limit == null ? activities : activities.take(limit!).toList();

                    return Column(
                      children: visibleItems
                          .map(
                            (activity) => _buildAdminActivityEntry(
                              context,
                              activity['title'] as String,
                              activity['time'] as String,
                              activity['icon'] as IconData,
                              activity['color'] as Color,
                            ),
                          )
                          .toList(),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

Widget _buildAdminActivityEntry(
  BuildContext context,
  String title,
  String time,
  IconData icon,
  Color color,
) {
  return Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AdminActivityDetailView(
              title: title,
              time: time,
              icon: icon,
              color: color,
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.01),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF342361),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    time,
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
          ],
        ),
      ),
    ),
  );
}

Widget _buildAdminPreviewBanner() {
  return Container(
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.orange.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
    ),
    child: const Row(
      children: [
        Icon(Icons.visibility_outlined, color: Colors.orange),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            "Preview mode: Firebase web is not connected, so admin data is using sample content for UI editing.",
            style: TextStyle(
              color: Color(0xFF7A4B00),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

void _showPreviewMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}

class AdminDashboardView extends StatefulWidget {
  const AdminDashboardView({super.key});

  @override
  State<AdminDashboardView> createState() => _AdminDashboardViewState();
}

class _AdminDashboardViewState extends State<AdminDashboardView> {
  int _selectedTab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text("Admin Dashboard", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: false,
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16, top: 8, bottom: 8),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: IconButton(
              icon: const Icon(Icons.logout, color: Colors.redAccent, size: 20),
              tooltip: "Logout",
              onPressed: () async {
                if (_adminFirebaseReady) {
                  await FirebaseAuth.instance.signOut();
                }
                if (context.mounted) {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (context) => const LoginView()),
                    (route) => false,
                  );
                }
              },
            ),
          )
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _buildMainContent(),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: (index) => setState(() => _selectedTab = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF4F378A),
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            activeIcon: Icon(Icons.dashboard),
            label: 'Admin',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people_outline),
            activeIcon: Icon(Icons.people),
            label: 'Applications',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet_outlined),
            activeIcon: Icon(Icons.account_balance_wallet),
            label: 'Funds',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.campaign_outlined),
            activeIcon: Icon(Icons.campaign),
            label: 'Content',
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    switch (_selectedTab) {
      case 0: return const AdminOverview();
      case 1: return const AdminApplicationsList();
      case 2: return const AdminWithdrawalsList();
      case 3: return const AdminContentManagement();
      default: return const AdminOverview();
    }
  }
}

// --- ADMIN OVERVIEW TAB ---
class AdminOverview extends StatelessWidget {
  const AdminOverview({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (!_adminFirebaseReady) _buildAdminPreviewBanner(),
        const Row(
          children: [
            Icon(Icons.analytics_outlined, color: Color(0xFF342361), size: 28),
            SizedBox(width: 12),
            Text(
              "System Overview",
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF342361),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        
        // Dynamic stats from Firestore
        _adminFirebaseReady
            ? StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('users').snapshots(),
                builder: (context, userSnap) {
                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('applications').snapshots(),
                    builder: (context, appSnap) {
                      return StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance.collection('withdrawals').snapshots(),
                        builder: (context, withdrawSnap) {
                          final totalScholars = userSnap.hasData ? userSnap.data!.docs.length : 0;
                          final pendingApps = appSnap.hasData ? appSnap.data!.docs.where((d) => d['status'] == 'PENDING').length : 0;
                          final pendingWithdraws = withdrawSnap.hasData ? withdrawSnap.data!.docs.where((d) => d['status'] == 'Pending').length : 0;
                          
                          return StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance.collection('grants').snapshots(),
                            builder: (context, grantSnap) {
                              final activeGrants = grantSnap.hasData ? grantSnap.data!.docs.length : 0;

                              return GridView.count(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                crossAxisCount: 2,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                                childAspectRatio: 1.1,
                                children: [
                                  _buildStatCard("Total Scholars", totalScholars.toString(), Icons.people, Colors.blue),
                                  _buildStatCard("Pending Apps", pendingApps.toString(), Icons.assignment, Colors.orange),
                                  _buildStatCard("Pending Payouts", pendingWithdraws.toString(), Icons.payments, Colors.green),
                                  _buildStatCard("Active Grants", activeGrants.toString(), Icons.campaign, Colors.purple),
                                ],
                              );
                            },
                          );
                        },
                      );
                    },
                  );
                },
              )
            : GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 1.1,
                children: [
                  _buildStatCard("Total Scholars", _previewScholars.length.toString(), Icons.people, Colors.blue),
                  _buildStatCard("Pending Apps", "1", Icons.assignment, Colors.orange),
                  _buildStatCard("Pending Payouts", "1", Icons.payments, Colors.green),
                  _buildStatCard("Active Grants", _previewGrants.length.toString(), Icons.campaign, Colors.purple),
                ],
              ),
        const SizedBox(height: 32),
        // Added button to access Scholars List
        ElevatedButton.icon(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => Scaffold(
                appBar: AppBar(title: const Text("Scholar Management")),
                body: const AdminScholarsList(),
              )),
            );
          },
          icon: const Icon(Icons.people),
          label: const Text("Manage Scholars List"),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4F378A),
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Recent Activity",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF342361)),
            ),
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AdminRecentActivityView(),
                  ),
                );
              },
              child: const Text("View All", style: TextStyle(color: Color(0xFF4F378A))),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const AdminRecentActivityFeed(limit: 3),
      ],
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.1), width: 1),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              color: Colors.black45,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class AdminRecentActivityView extends StatelessWidget {
  const AdminRecentActivityView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text("Recent Activity"),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (!_adminFirebaseReady) _buildAdminPreviewBanner(),
          const AdminRecentActivityFeed(),
        ],
      ),
    );
  }
}

class AdminActivityDetailView extends StatelessWidget {
  final String title;
  final String time;
  final IconData icon;
  final Color color;

  const AdminActivityDetailView({
    super.key,
    required this.title,
    required this.time,
    required this.icon,
    required this.color,
  });

  String get _activityType {
    final lower = title.toLowerCase();
    if (lower.contains('application')) return 'Application Update';
    if (lower.contains('payout') || lower.contains('withdrawal')) return 'Fund Transaction';
    if (lower.contains('grant')) return 'Grant Management';
    if (lower.contains('scholar')) return 'Scholar Record';
    if (lower.contains('wallet balance')) return 'Scholar Record';
    return 'Admin Activity';
  }

  String get _activityDescription {
    final lower = title.toLowerCase();
    if (lower.contains('submitted a new application')) {
      return 'A scholar submitted a new application and it is waiting for review in the Applications tab.';
    }
    if (lower.contains('application approved')) {
      return 'An admin approved an application from the Applications tab and the status was saved to Firestore.';
    }
    if (lower.contains('application rejected')) {
      return 'An admin rejected an application from the Applications tab and the updated status was saved to Firestore.';
    }
    if (lower.contains('requested a payout')) {
      return 'A scholar submitted a withdrawal request and it is now visible in the Funds tab for admin review.';
    }
    if (lower.contains('payout processed')) {
      return 'A payout request was processed and its fund transaction status should now appear as completed.';
    }
    if (lower.contains('payout rejected')) {
      return 'A payout request was reviewed in the Funds tab and marked as rejected.';
    }
    if (lower.contains('grant')) {
      return 'A grant record was created or published from the grant management section.';
    }
    if (lower.contains('added to the scholars list')) {
      return 'A scholar profile was added or synced into the users collection for admin management.';
    }
    if (lower.contains('wallet balance updated')) {
      return 'A scholar wallet balance was updated from the admin scholar management screen.';
    }
    if (lower.contains('reviewed')) {
      return 'An admin reviewed a pending financial request and updated its status in the funds section.';
    }
    return 'This activity was recorded by the admin dashboard as part of the current system timeline.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text("Activity Details"),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF342361),
                  ),
                ),
                const SizedBox(height: 12),
                _buildDetailRow("Type", _activityType),
                _buildDetailRow("Time", time),
                _buildDetailRow("Status", "Recorded"),
                const SizedBox(height: 20),
                const Text(
                  "Description",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF342361),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _activityDescription,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xFF342361),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- ADMIN SCHOLAR DETAIL VIEW ---
class AdminScholarDetailView extends StatefulWidget {
  final String scholarId;
  final Map<String, dynamic> scholarData;
  const AdminScholarDetailView({super.key, required this.scholarId, required this.scholarData});

  @override
  State<AdminScholarDetailView> createState() => _AdminScholarDetailViewState();
}

class AdminScholarPreviewView extends StatelessWidget {
  final Map<String, dynamic> scholarData;
  const AdminScholarPreviewView({super.key, required this.scholarData});

  @override
  Widget build(BuildContext context) {
    final double balance = (scholarData['wallet_balance'] ?? 0.0).toDouble();

    return Scaffold(
      appBar: AppBar(title: const Text("Manage Scholar")),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildAdminPreviewBanner(),
          const CircleAvatar(radius: 40, backgroundColor: Color(0xFF4F378A), child: Icon(Icons.person, size: 40, color: Colors.white)),
          const SizedBox(height: 16),
          Center(child: Text(scholarData['full_name'] ?? "No Name", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          Center(child: Text(scholarData['email'] ?? "", style: const TextStyle(color: Colors.grey))),
          const SizedBox(height: 32),
          const Text("Financial Management", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Text("Wallet Balance: ₱${balance.toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => _showPreviewMessage(context, "Preview mode only: connect Firebase web config to save admin changes."),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F378A), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50)),
            child: const Text("Update Balance"),
          ),
          const SizedBox(height: 32),
          const Text("Scholarship Info", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 8),
          _infoTile("Scholar Number", scholarData['scholar_number']),
          _infoTile("Applicant Type", scholarData['applicant_type']),
          _infoTile("Year Level", scholarData['year_level']),
          _infoTile("Course", scholarData['course']),
        ],
      ),
    );
  }

  Widget _infoTile(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value?.toString() ?? "Not set", style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _AdminScholarDetailViewState extends State<AdminScholarDetailView> {
  late TextEditingController _balanceController;

  @override
  void initState() {
    super.initState();
    _balanceController = TextEditingController(
      text: (widget.scholarData['wallet_balance'] ?? 0.0).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    var data = widget.scholarData;
    
    return Scaffold(
      appBar: AppBar(title: const Text("Manage Scholar")),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const CircleAvatar(radius: 40, backgroundColor: Color(0xFF4F378A), child: Icon(Icons.person, size: 40, color: Colors.white)),
          const SizedBox(height: 16),
          Center(child: Text(data['full_name'] ?? "No Name", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          Center(child: Text(data['email'] ?? "", style: const TextStyle(color: Colors.grey))),
          const SizedBox(height: 32),
          const Text("Financial Management", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 16),
          TextField(
            controller: _balanceController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "Wallet Balance (₱)",
              border: OutlineInputBorder(),
              prefixText: "₱ ",
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () async {
              double newBalance = double.tryParse(_balanceController.text) ?? 0.0;
              await FirebaseFirestore.instance.collection('users').doc(widget.scholarId).update({
                'wallet_balance': newBalance,
                'wallet_updated_at': FieldValue.serverTimestamp(),
              });
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Balance updated successfully")));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F378A), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50)),
            child: const Text("Update Balance"),
          ),
          const SizedBox(height: 32),
          const Text("Scholarship Info", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 8),
          _infoTile("Scholar Number", data['scholar_number']),
          _infoTile("Applicant Type", data['applicant_type']),
          _infoTile("Year Level", data['year_level']),
          _infoTile("Course", data['course']),
        ],
      ),
    );
  }

  Widget _infoTile(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value?.toString() ?? "Not set", style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// --- ADMIN SCHOLARS LIST TAB ---
class AdminScholarsList extends StatefulWidget {
  const AdminScholarsList({super.key});

  @override
  State<AdminScholarsList> createState() => _AdminScholarsListState();
}

class _AdminScholarsListState extends State<AdminScholarsList> {
  String _searchQuery = "";
  bool _onlyApproved = false;

  void _showQuickUpdateBalance(BuildContext context, String userId, String name, double currentBalance) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Add Funds to $name"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Current Balance: ₱${currentBalance.toStringAsFixed(2)}", style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: "Amount to Add (₱)",
                border: OutlineInputBorder(),
                prefixText: "₱ ",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              double amount = double.tryParse(controller.text) ?? 0.0;
              if (amount > 0) {
                final userRef = FirebaseFirestore.instance.collection('users').doc(userId);
                await FirebaseFirestore.instance.runTransaction((transaction) async {
                  final snap = await transaction.get(userRef);
                  double balance = (snap.get('wallet_balance') ?? 0.0).toDouble();
                  transaction.update(userRef, {
                    'wallet_balance': balance + amount,
                    'wallet_updated_at': FieldValue.serverTimestamp(),
                  });
                  
                  // Log transaction
                  final transRef = FirebaseFirestore.instance.collection('transactions').doc();
                  transaction.set(transRef, {
                    'user_id': userId,
                    'amount': amount,
                    'type': 'DEPOSIT',
                    'status': 'PASSED',
                    'title': 'Admin Top-up',
                    'timestamp': FieldValue.serverTimestamp(),
                  });
                });
                if (mounted) Navigator.pop(context);
              }
            },
            child: const Text("Update Balance"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_adminFirebaseReady) {
      // Preview mode logic (simplified for briefness)
      return ListView.builder(
        padding: const EdgeInsets.all(24),
        itemCount: _previewScholars.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _buildAdminPreviewBanner();
          final data = _previewScholars[index - 1];
          return _buildScholarTile(context, "preview-$index", data);
        },
      );
    }

    return Column(
      children: [
        // Search & Filter Header
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
                  decoration: InputDecoration(
                    hintText: "Search name or ID...",
                    prefixIcon: const Icon(Icons.search, size: 20),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: EdgeInsets.zero,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => setState(() => _onlyApproved = !_onlyApproved),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _onlyApproved ? const Color(0xFF4F378A) : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _onlyApproved ? Colors.transparent : Colors.grey.shade200),
                  ),
                  child: Icon(Icons.verified_user_outlined, color: _onlyApproved ? Colors.white : const Color(0xFF4F378A), size: 20),
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('users').snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              
              var docs = snapshot.data!.docs.where((doc) {
                var data = doc.data() as Map<String, dynamic>;
                if (doc.id == 'admin_system') return false;
                
                bool matchesSearch = (data['full_name'] ?? "").toString().toLowerCase().contains(_searchQuery) ||
                                     (data['scholar_number'] ?? "").toString().toLowerCase().contains(_searchQuery);
                
                // For "Approved", we check if they have a wallet balance > 0 or a specific flag
                // In this app context, let's assume 'Approved' means they have an assigned Scholar Number that isn't empty
                bool isApproved = (data['scholar_number'] != null && data['scholar_number'].toString().isNotEmpty);
                
                if (_onlyApproved && !isApproved) return false;
                return matchesSearch;
              }).toList();

              if (docs.isEmpty) {
                return const Center(child: Text("No scholars found matching criteria."));
              }

              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  var doc = docs[index];
                  var data = doc.data() as Map<String, dynamic>;
                  return _buildScholarTile(context, doc.id, data);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildScholarTile(BuildContext context, String id, Map<String, dynamic> data) {
    double balance = (data['wallet_balance'] ?? 0.0).toDouble();
    String name = data['full_name'] ?? "No Name";
    bool isApproved = (data['scholar_number'] != null && data['scholar_number'].toString().isNotEmpty);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
        leading: Stack(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xFF4F378A).withValues(alpha: 0.1),
              child: const Icon(Icons.person, color: Color(0xFF4F378A)),
            ),
            if (isApproved)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle),
                  child: const Icon(Icons.check, size: 8, color: Colors.white),
                ),
              ),
          ],
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(name, 
                style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF342361), fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isApproved)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
                child: const Text("APPROVED", style: TextStyle(color: Colors.green, fontSize: 8, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        subtitle: Text(
          "${data['scholar_number'] ?? 'No ID'} • ${data['year_level'] ?? 'N/A'}",
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text("₱${balance.toStringAsFixed(2)}",
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 14),
                ),
                const Text("Balance", style: TextStyle(fontSize: 9, color: Colors.grey)),
              ],
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.add_circle_outline, color: Color(0xFF4F378A), size: 24),
              onPressed: () => _showQuickUpdateBalance(context, id, name, balance),
              tooltip: "Quick Add Funds",
            ),
          ],
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => AdminScholarDetailView(scholarId: id, scholarData: data)),
          );
        },
      ),
    );
  }
}

// Helper for passing data to detail view if needed from local list

// --- ADMIN APPLICATIONS TAB ---
class AdminApplicationsList extends StatefulWidget {
  const AdminApplicationsList({super.key});

  @override
  State<AdminApplicationsList> createState() => _AdminApplicationsListState();
}

class _AdminApplicationsListState extends State<AdminApplicationsList> {
  String _searchQuery = "";
  String _statusFilter = "ALL";
  final Set<String> _selectedApplicationIds = {};

  Future<void> _handleBulkApplicationAction(List<QueryDocumentSnapshot> docs, String action) async {
    final docsToProcess = docs.where((doc) => _selectedApplicationIds.contains(doc.id)).toList();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Processing ${docsToProcess.length} applications..."), duration: const Duration(seconds: 1)),
    );

    if (action == 'NEXT') {
      final pendingDocs = docsToProcess.where((doc) => (doc.data() as Map<String, dynamic>)['status'] == 'PENDING').toList();
      final verifyingDocs = docsToProcess.where((doc) => (doc.data() as Map<String, dynamic>)['status'] == 'VERIFYING').toList();

      for (var doc in pendingDocs) {
        await doc.reference.update({'status': 'VERIFYING'});
      }

      if (verifyingDocs.isNotEmpty && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => AdminDispatchExamView(applicationDocs: verifyingDocs)),
        );
      }
    } else {
      for (var doc in docsToProcess) {
        final data = doc.data() as Map<String, dynamic>;
        
        if (action == 'PASS') {
          final userId = data['user_id'];
          final grantTitle = data['grant_title'] ?? "Scholarship";
          final grantAmount = grantTitle.contains("Taytay") ? 15000.0 : 10000.0;

          await FirebaseFirestore.instance.runTransaction((transaction) async {
            final userRef = FirebaseFirestore.instance.collection('users').doc(userId);
            final userS = await transaction.get(userRef);
            final bal = (userS.get('wallet_balance') ?? 0.0).toDouble();

            transaction.update(doc.reference, {'status': 'PASSED', 'reviewed_at': FieldValue.serverTimestamp()});
            transaction.update(userRef, {'wallet_balance': bal + grantAmount, 'wallet_updated_at': FieldValue.serverTimestamp()});
            
            final tRef = FirebaseFirestore.instance.collection('transactions').doc();
            transaction.set(tRef, {
              'user_id': userId, 'amount': grantAmount, 'type': 'GRANT', 'status': 'PASSED',
              'title': '$grantTitle Credit', 'timestamp': FieldValue.serverTimestamp(),
            });
          });
        } else if (action == 'FAIL') {
          await doc.reference.update({'status': 'FAILED', 'reviewed_at': FieldValue.serverTimestamp()});
        }
      }
    }
    
    if (mounted) {
      setState(() {
        _selectedApplicationIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Batch processing completed.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_adminFirebaseReady) {
      return ListView.builder(
        padding: const EdgeInsets.all(24),
        itemCount: _previewApplications.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _buildAdminPreviewBanner();
          final data = _previewApplications[index - 1];
          return _buildApplicationCard(context, "preview-$index", data);
        },
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('applications').orderBy('timestamp', descending: true).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        
        var allDocs = snapshot.data!.docs;
        var filteredDocs = allDocs.where((doc) {
          var data = doc.data() as Map<String, dynamic>;
          String status = (data['status'] ?? "PENDING").toUpperCase();
          String name = (data['applicant_name'] ?? "").toString().toLowerCase();
          String grant = (data['grant_title'] ?? "").toString().toLowerCase();

          bool matchesSearch = name.contains(_searchQuery) || grant.contains(_searchQuery);
          bool matchesStatus = _statusFilter == "ALL" || status == _statusFilter;

          return matchesSearch && matchesStatus;
        }).toList();

        return Stack(
          children: [
            Column(
              children: [
                // Search & Filter Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                  child: Column(
                    children: [
                      TextField(
                        onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
                        decoration: InputDecoration(
                          hintText: "Search applicant or grant...",
                          prefixIcon: const Icon(Icons.search, size: 20),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: EdgeInsets.zero,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: ["ALL", "PENDING", "VERIFYING", "FOR_EXAM", "PASSED", "FAILED"].map((status) {
                            bool isSelected = _statusFilter == status;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(status, style: TextStyle(fontSize: 10, color: isSelected ? Colors.white : Colors.black87)),
                                selected: isSelected,
                                selectedColor: const Color(0xFF4F378A),
                                onSelected: (val) => setState(() => _statusFilter = status),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      if (filteredDocs.isNotEmpty)
                        Row(
                          children: [
                            Checkbox(
                              value: _selectedApplicationIds.length == filteredDocs.length && filteredDocs.isNotEmpty,
                              onChanged: (val) {
                                setState(() {
                                  if (val == true) {
                                    _selectedApplicationIds.addAll(filteredDocs.map((d) => d.id));
                                  } else {
                                    _selectedApplicationIds.clear();
                                  }
                                });
                              },
                            ),
                            const Text("Select All Filtered", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF342361), fontSize: 12)),
                          ],
                        ),
                    ],
                  ),
                ),

                Expanded(
                  child: filteredDocs.isEmpty 
                    ? const Center(child: Text("No applications found."))
                    : ListView.builder(
                        padding: const EdgeInsets.all(24),
                        itemCount: filteredDocs.length,
                        itemBuilder: (context, index) {
                          return _buildApplicationCard(context, filteredDocs[index].id, filteredDocs[index].data() as Map<String, dynamic>, filteredDocs[index]);
                        },
                      ),
                ),
              ],
            ),
            if (_selectedApplicationIds.isNotEmpty)
              Positioned(
                bottom: 20,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4F378A),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("${_selectedApplicationIds.length} Applications Selected", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _bulkActionButton("Move Selected to Next Stage", Icons.next_plan_outlined, () => _handleBulkApplicationAction(filteredDocs, 'NEXT')),
                            const SizedBox(width: 8),
                            _bulkActionButton("Mark Selected as Passed", Icons.check_circle_outline, () => _handleBulkApplicationAction(filteredDocs, 'PASS')),
                            const SizedBox(width: 8),
                            _bulkActionButton("Mark Selected as Failed", Icons.highlight_off, () => _handleBulkApplicationAction(filteredDocs, 'FAIL')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _bulkActionButton(String label, IconData icon, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF4F378A),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildApplicationCard(BuildContext context, String id, Map<String, dynamic> data, [QueryDocumentSnapshot? doc]) {
    String status = (data['status'] ?? "PENDING").toString().toUpperCase();
    bool isSelected = _selectedApplicationIds.contains(id);
    
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            if (doc != null) {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => AdminApplicationDetailView(applicationDoc: doc)),
              );
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: isSelected,
                  onChanged: (val) {
                    setState(() {
                      if (val == true) {
                        _selectedApplicationIds.add(id);
                      } else {
                        _selectedApplicationIds.remove(id);
                      }
                    });
                  },
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              data['grant_title'] ?? "Unknown Grant",
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF342361)),
                            ),
                          ),
                          _buildStatusBadge(status),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildQualificationsSummary(data),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.access_time, size: 14, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text(_formatDateTimeValue(data['timestamp']), style: const TextStyle(color: Colors.grey, fontSize: 11)),
                        ],
                      ),
                      
                      // View Details hint
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text("View Details", style: TextStyle(color: Color(0xFF4F378A), fontSize: 12, fontWeight: FontWeight.bold)),
                          SizedBox(width: 4),
                          Icon(Icons.chevron_right, size: 16, color: Color(0xFF4F378A)),
                        ],
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
}

// --- ADMIN DISPATCH EXAM VIEW ---
class AdminDispatchExamView extends StatefulWidget {
  final List<QueryDocumentSnapshot> applicationDocs;
  const AdminDispatchExamView({super.key, required this.applicationDocs});

  @override
  State<AdminDispatchExamView> createState() => _AdminDispatchExamViewState();
}

class _AdminDispatchExamViewState extends State<AdminDispatchExamView> {
  final _roomController = TextEditingController(text: "204");
  final _buildingController = TextEditingController(text: "B");
  final _seatController = TextEditingController(text: "23");
  final _timeController = TextEditingController(text: "8:00 AM");
  final _dateController = TextEditingController(text: "May 20, 2026");
  final _addressController = TextEditingController(text: "ICCT Colleges - Sumulong Highway, Cainta, Rizal");
  
  double _lat = 14.6141; // Cainta area
  double _lng = 121.1215;
  bool _isSearching = false;

  Future<void> _handleSearch() async {
    if (_addressController.text.isEmpty) return;
    setState(() => _isSearching = true);
    try {
      List<Location> locations = await locationFromAddress(_addressController.text);
      if (locations.isNotEmpty) {
        if (mounted) {
          setState(() {
            _lat = locations.first.latitude;
            _lng = locations.first.longitude;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Location not found. Try a more specific address.")),
        );
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _dispatch() async {
    if (_addressController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please provide a testing center address")));
      return;
    }

    setState(() => _isSearching = true);
    
    for (var doc in widget.applicationDocs) {
      await doc.reference.update({
        'status': 'FOR_EXAM',
        'exam_room': _roomController.text,
        'exam_building': _buildingController.text,
        'exam_seat': widget.applicationDocs.length > 1 ? "Assigned" : _seatController.text,
        'exam_time': _timeController.text,
        'exam_date': _dateController.text,
        'exam_address': _addressController.text,
        'exam_lat': _lat,
        'exam_lng': _lng,
      });
    }

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Exam details dispatched to ${widget.applicationDocs.length} students")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Dispatch Exam Details")),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text("Dispatching to ${widget.applicationDocs.length} students", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 24),
          _buildInput("Exam Date", _dateController, Icons.calendar_today),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _buildInput("Room", _roomController, Icons.room)),
              const SizedBox(width: 16),
              Expanded(child: _buildInput("Building", _buildingController, Icons.apartment)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _buildInput("Seat", _seatController, Icons.event_seat, enabled: widget.applicationDocs.length == 1)),
              const SizedBox(width: 16),
              Expanded(child: _buildInput("Time", _timeController, Icons.access_time)),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 24),
          const Text("Testing Center Location", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          TextField(
            controller: _addressController,
            decoration: InputDecoration(
              labelText: "Search Address",
              prefixIcon: const Icon(Icons.location_on),
              suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _handleSearch),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          // Mock Map Picker
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: Stack(
              children: [
                CustomPaint(painter: MapGridPainter(), size: Size.infinite),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.location_pin, color: Colors.red, size: 40),
                      Text("Lat: ${_lat.toStringAsFixed(4)}, Lng: ${_lng.toStringAsFixed(4)}", 
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                if (_isSearching) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: _dispatch,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4F378A),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 55),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text("Dispatch Now", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildInput(String label, TextEditingController controller, IconData icon, {bool enabled = true}) {
    return TextField(
      controller: controller,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
        hintText: !enabled ? "Bulk Auto-assigned" : null,
      ),
    );
  }
}

class AdminApplicationDetailView extends StatelessWidget {
  final QueryDocumentSnapshot applicationDoc;
  const AdminApplicationDetailView({super.key, required this.applicationDoc});

  @override
  Widget build(BuildContext context) {
    final data = applicationDoc.data() as Map<String, dynamic>;
    final status = (data['status'] ?? 'PENDING').toString().toUpperCase();
    final userId = data['user_id'];
    final Map<String, dynamic> attachedDocs = data['attached_documents'] ?? {};

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(title: const Text("Review Application"), backgroundColor: Colors.white, elevation: 0),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(userId).snapshots(),
        builder: (context, userSnap) {
          String applicantName = data['applicant_name'] ?? "Unknown";
          String scholarNo = "N/A";
          String email = "N/A";
          String? profilePhoto;

          if (userSnap.hasData && userSnap.data!.exists) {
            final userData = userSnap.data!.data() as Map<String, dynamic>;
            applicantName = userData['full_name'] ?? applicantName;
            scholarNo = userData['scholar_number'] ?? "N/A";
            email = userData['email'] ?? "N/A";
            profilePhoto = userData['profile_photo_path'];
          }

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // Applicant Profile Card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: const Color(0xFF4F378A),
                      backgroundImage: profilePhoto != null ? FileImage(File(profilePhoto)) : null,
                      child: profilePhoto == null ? const Icon(Icons.person, color: Colors.white) : null,
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(applicantName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          Text("ID: $scholarNo", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                          Text(email, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                    ),
                    _buildStatusBadge(status),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Application Info
              const Text("Application Details", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: Column(
                  children: [
                    _infoRow("Grant", data['grant_title'] ?? "N/A"),
                    _infoRow("Submitted", _formatDateTimeValue(data['timestamp'])),
                    _infoRow("Home Address", data['address'] ?? "N/A"),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Documents Section
              const Text("Attached Documents", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              if (attachedDocs.isEmpty)
                const Text("No documents attached to this application.", style: TextStyle(color: Colors.grey, fontSize: 13))
              else
                ...attachedDocs.entries.map((entry) => _buildDocTile(context, entry.key, entry.value)),

              const SizedBox(height: 32),

              // Action Buttons
              if (status != "PASSED" && status != "FAILED") ...[
                const Text("Review Actions", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                if (status == "PENDING")
                  _actionButton("Verify Documents", Colors.blue, () {
                    applicationDoc.reference.update({'status': 'VERIFYING'});
                  }),
                if (status == "VERIFYING")
                  _actionButton("Schedule Exam", Colors.purple, () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AdminDispatchExamView(applicationDocs: [applicationDoc]),
                      ),
                    );
                  }),
                if (status == "FOR_EXAM")
                  _actionButton("Approve Scholarship", Colors.green, () async {
                    final grantTitle = data['grant_title'] ?? "Scholarship";
                    final grantAmount = grantTitle.contains("Taytay") ? 15000.0 : 10000.0;
                    
                    await FirebaseFirestore.instance.runTransaction((transaction) async {
                      final userRef = FirebaseFirestore.instance.collection('users').doc(userId);
                      final userS = await transaction.get(userRef);
                      final bal = (userS.get('wallet_balance') ?? 0.0).toDouble();

                      transaction.update(applicationDoc.reference, {'status': 'PASSED', 'reviewed_at': FieldValue.serverTimestamp()});
                      transaction.update(userRef, {'wallet_balance': bal + grantAmount, 'wallet_updated_at': FieldValue.serverTimestamp()});
                      
                      final tRef = FirebaseFirestore.instance.collection('transactions').doc();
                      transaction.set(tRef, {
                        'user_id': userId, 'amount': grantAmount, 'type': 'GRANT', 'status': 'PASSED',
                        'title': '$grantTitle Credit', 'timestamp': FieldValue.serverTimestamp(),
                      });
                    });
                    if (context.mounted) Navigator.pop(context);
                  }),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    applicationDoc.reference.update({'status': 'FAILED', 'reviewed_at': FieldValue.serverTimestamp()});
                    Navigator.pop(context);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Reject Application", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
              const SizedBox(height: 40),
            ],
          );
        },
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildDocTile(BuildContext context, String title, Map<String, dynamic> file) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey.shade100)),
      child: ListTile(
        leading: const Icon(Icons.description, color: Color(0xFF4F378A)),
        title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        subtitle: Text(file['name'] ?? "file.pdf", style: const TextStyle(fontSize: 11)),
        trailing: const Icon(Icons.visibility_outlined, color: Colors.grey, size: 20),
        onTap: () {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(title),
              content: file['path'] != null 
                ? Image.file(File(file['path']), height: 300, fit: BoxFit.contain, errorBuilder: (c, e, s) => const Icon(Icons.insert_drive_file, size: 100))
                : const Icon(Icons.insert_drive_file, size: 100),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close"))],
            ),
          );
        },
      ),
    );
  }

  Widget _actionButton(String label, Color color, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}

// --- ADMIN DISPATCH EXAM VIEW ---


// --- ADMIN WITHDRAWALS TAB ---
class AdminWithdrawalsList extends StatefulWidget {
  const AdminWithdrawalsList({super.key});

  @override
  State<AdminWithdrawalsList> createState() => _AdminWithdrawalsListState();
}

class _AdminWithdrawalsListState extends State<AdminWithdrawalsList> {
  final Set<String> _selectedIds = {};

  Future<void> _handleWithdrawalAction(QueryDocumentSnapshot doc, Map<String, dynamic> data, bool isApprove) async {
    final userId = data['user_id'];
    final amount = (data['amount'] ?? 0.0).toDouble();

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final userRef = FirebaseFirestore.instance.collection('users').doc(userId);
      
      if (!isApprove) {
        // Refund if declined
        final userSnap = await transaction.get(userRef);
        final currentBalance = (userSnap.get('wallet_balance') ?? 0.0).toDouble();
        transaction.update(userRef, {
          'wallet_balance': currentBalance + amount,
          'wallet_updated_at': FieldValue.serverTimestamp(),
        });
      }

      transaction.update(doc.reference, {
        'status': isApprove ? 'Completed' : 'Rejected',
        'processed_at': FieldValue.serverTimestamp(),
      });

      final transQuery = await FirebaseFirestore.instance.collection('transactions')
          .where('user_id', isEqualTo: userId)
          .where('type', isEqualTo: 'WITHDRAWAL')
          .where('status', isEqualTo: 'PENDING')
          .limit(1).get();
      
      if (transQuery.docs.isNotEmpty) {
        transaction.update(transQuery.docs.first.reference, {
          'status': isApprove ? 'COMPLETED' : 'REJECTED',
          'title': isApprove ? 'Withdrawal Completed' : 'Withdrawal Rejected (Refunded)',
        });
      }
    });
  }

  Future<void> _handleBulkAction(List<QueryDocumentSnapshot> pendingDocs, bool isApprove) async {
    final docsToProcess = pendingDocs.where((doc) => _selectedIds.contains(doc.id)).toList();
    
    // Show status
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Processing ${docsToProcess.length} requests..."), duration: const Duration(seconds: 1)),
    );

    for (var doc in docsToProcess) {
      await _handleWithdrawalAction(doc, doc.data() as Map<String, dynamic>, isApprove);
    }

    if (mounted) {
      setState(() {
        _selectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${docsToProcess.length} requests ${isApprove ? 'approved' : 'declined'}.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_adminFirebaseReady) {
      return ListView.builder(
        padding: const EdgeInsets.all(24),
        itemCount: _previewWithdrawals.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _buildAdminPreviewBanner();
          final data = _previewWithdrawals[index - 1];
          final String status = data['status'] ?? "Pending";
          final double amount = (data['amount'] ?? 0.0).toDouble();

          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10)
              ],
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: status == "Pending" ? Colors.orange.withValues(alpha: 0.1) : Colors.green.withValues(alpha: 0.1),
                child: Icon(
                  status == "Pending" ? Icons.hourglass_empty : Icons.check,
                  color: status == "Pending" ? Colors.orange : Colors.green,
                  size: 20,
                ),
              ),
              title: Text(
                "₱${amount.toStringAsFixed(2)}",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              subtitle: Text("Method: ${data['method'] ?? 'Payout'} • $status"),
              trailing: const Icon(Icons.chevron_right, color: Colors.grey),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AdminWithdrawalPreviewDetailView(withdrawalData: data),
                  ),
                );
              },
            ),
          );
        },
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('withdrawals').orderBy('timestamp', descending: true).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        var docs = snapshot.data!.docs;
        var pendingDocs = docs.where((doc) => (doc.data() as Map<String, dynamic>)['status'] == 'Pending').toList();

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.payments_outlined, size: 64, color: Colors.grey[300]),
                const SizedBox(height: 16),
                const Text("No pending payouts", style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }

        return Stack(
          children: [
            Column(
              children: [
                if (pendingDocs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _selectedIds.length == pendingDocs.length && pendingDocs.isNotEmpty,
                          onChanged: (val) {
                            setState(() {
                              if (val == true) {
                                _selectedIds.addAll(pendingDocs.map((d) => d.id));
                              } else {
                                _selectedIds.clear();
                              }
                            });
                          },
                        ),
                        const Text("Select All Pending", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(24),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      var data = docs[index].data() as Map<String, dynamic>;
                      String status = data['status'] ?? "Pending";
                      double amount = (data['amount'] ?? 0.0).toDouble();
                      String userId = data['user_id'] ?? "";
                      String method = data['method'] ?? "Payout";
                      String accountNo = data['account_number'] ?? "N/A";
                      String id = docs[index].id;

                      return StreamBuilder<DocumentSnapshot>(
                        stream: FirebaseFirestore.instance.collection('users').doc(userId).snapshots(),
                        builder: (context, userSnap) {
                          String userName = "Loading...";
                          String riskFlag = "Verified";
                          Color flagColor = Colors.green;

                          if (userSnap.hasData && userSnap.data!.exists) {
                            var userData = userSnap.data!.data() as Map<String, dynamic>;
                            userName = userData['full_name'] ?? "Unknown User";
                            
                            Timestamp? createdAt = userData['created_at'] as Timestamp?;
                            if (createdAt != null) {
                              final daysOld = DateTime.now().difference(createdAt.toDate()).inDays;
                              if (daysOld < 7) {
                                riskFlag = "New Account";
                                flagColor = Colors.orange;
                              }
                            }
                            
                            double bal = (userData['wallet_balance'] ?? 0.0).toDouble();
                            if (bal > 20000) {
                              riskFlag = "High Balance";
                              flagColor = Colors.redAccent;
                            }
                          }

                          return Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))
                              ],
                            ),
                            child: Row(
                              children: [
                                if (status == "Pending")
                                  Checkbox(
                                    value: _selectedIds.contains(id),
                                    onChanged: (val) {
                                      setState(() {
                                        if (val == true) {
                                          _selectedIds.add(id);
                                        } else {
                                          _selectedIds.remove(id);
                                        }
                                      });
                                    },
                                  ),
                                Expanded(
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: CircleAvatar(
                                      radius: 24,
                                      backgroundColor: status == "Pending" ? Colors.orange.withValues(alpha: 0.1) : (status == "Rejected" ? Colors.red.withValues(alpha: 0.1) : Colors.green.withValues(alpha: 0.1)),
                                      child: Icon(
                                        status == "Pending" ? Icons.hourglass_empty : (status == "Rejected" ? Icons.close : Icons.check),
                                        color: status == "Pending" ? Colors.orange : (status == "Rejected" ? Colors.red : Colors.green),
                                        size: 24,
                                      ),
                                    ),
                                    title: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          "₱${amount.toStringAsFixed(2)}",
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Color(0xFF342361)),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: flagColor.withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            riskFlag,
                                            style: TextStyle(color: flagColor, fontSize: 10, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ],
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 4),
                                        Text(userName, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 14)),
                                        Text("$method • $accountNo", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                      ],
                                    ),
                                    trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => AdminWithdrawalDetailView(
                                            withdrawalDoc: docs[index],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
            if (_selectedIds.isNotEmpty)
              Positioned(
                bottom: 20,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4F378A),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Row(
                    children: [
                      Text("${_selectedIds.length} Selected", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => _handleBulkAction(pendingDocs, false),
                        child: const Text("Decline Selected", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () => _handleBulkAction(pendingDocs, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF4F378A),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text("Approve Selected", style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class AdminWithdrawalPreviewDetailView extends StatelessWidget {
  final Map<String, dynamic> withdrawalData;
  const AdminWithdrawalPreviewDetailView({super.key, required this.withdrawalData});

  @override
  Widget build(BuildContext context) {
    final status = (withdrawalData['status'] ?? 'Pending').toString();
    final amount = (withdrawalData['amount'] ?? 0.0).toDouble();

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text("Payout Details"),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildAdminPreviewBanner(),
          _buildWithdrawalDetailCard(
            amount: amount,
            method: (withdrawalData['method'] ?? 'Payout').toString(),
            status: status,
            requestedBy: (withdrawalData['user_id'] ?? 'Preview User').toString(),
            requestedAt: "Preview data",
            processedAt: status == 'Pending' ? "Not processed yet" : "Preview data",
          ),
          const SizedBox(height: 24),
          if (status == 'Pending') ...[
            OutlinedButton(
              onPressed: () => _showPreviewMessage(context, "Preview mode only: payout rejection is disabled."),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Colors.redAccent),
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text("Reject Request"),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _showPreviewMessage(context, "Preview mode only: payout completion is disabled."),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text("Approve Request"),
            ),
          ],
        ],
      ),
    );
  }
}

class AdminWithdrawalDetailView extends StatelessWidget {
  final QueryDocumentSnapshot withdrawalDoc;
  const AdminWithdrawalDetailView({super.key, required this.withdrawalDoc});

  @override
  Widget build(BuildContext context) {
    final data = withdrawalDoc.data() as Map<String, dynamic>;
    final status = (data['status'] ?? 'Pending').toString();
    final amount = (data['amount'] ?? 0.0).toDouble();
    final userId = (data['user_id'] ?? '').toString();

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text("Payout Details"),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance.collection('users').doc(userId).snapshots(),
            builder: (context, userSnapshot) {
              final userData = userSnapshot.data?.data() as Map<String, dynamic>?;
              final requestedBy =
                  (userData?['full_name'] ?? userData?['email'] ?? userId).toString();

              return _buildWithdrawalDetailCard(
                amount: amount,
                method: (data['method'] ?? 'Payout').toString(),
                status: status,
                requestedBy: requestedBy.isEmpty ? "Unknown User" : requestedBy,
                requestedAt: _formatDateTimeValue(data['timestamp']),
                processedAt: status == 'Pending'
                    ? "Not processed yet"
                    : _formatDateTimeValue(data['processed_at']),
              );
            },
          ),
          const SizedBox(height: 24),
          if (status == 'Pending') ...[
            OutlinedButton(
              onPressed: () async {
                final userId = data['user_id'];
                final amount = (data['amount'] ?? 0.0).toDouble();

                await FirebaseFirestore.instance.runTransaction((transaction) async {
                  final userRef = FirebaseFirestore.instance.collection('users').doc(userId);
                  final userSnap = await transaction.get(userRef);
                  final currentBalance = (userSnap.get('wallet_balance') ?? 0.0).toDouble();

                  transaction.update(withdrawalDoc.reference, {
                    'status': 'Rejected',
                    'processed_at': FieldValue.serverTimestamp(),
                  });

                  transaction.update(userRef, {
                    'wallet_balance': currentBalance + amount,
                    'wallet_updated_at': FieldValue.serverTimestamp(),
                  });

                  final transQuery = await FirebaseFirestore.instance.collection('transactions')
                      .where('user_id', isEqualTo: userId)
                      .where('type', isEqualTo: 'WITHDRAWAL')
                      .where('status', isEqualTo: 'PENDING')
                      .limit(1).get();
                  
                  if (transQuery.docs.isNotEmpty) {
                    transaction.update(transQuery.docs.first.reference, {
                      'status': 'REJECTED',
                      'title': 'Withdrawal Rejected (Refunded)',
                    });
                  }
                });

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Payout rejected and refunded")),
                  );
                  Navigator.pop(context);
                }
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Colors.redAccent),
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text("Reject Request"),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () async {
                final userId = data['user_id'];
                await FirebaseFirestore.instance.runTransaction((transaction) async {
                  transaction.update(withdrawalDoc.reference, {
                    'status': 'Completed',
                    'processed_at': FieldValue.serverTimestamp(),
                  });

                  final transQuery = await FirebaseFirestore.instance.collection('transactions')
                      .where('user_id', isEqualTo: userId)
                      .where('type', isEqualTo: 'WITHDRAWAL')
                      .where('status', isEqualTo: 'PENDING')
                      .limit(1).get();
                  
                  if (transQuery.docs.isNotEmpty) {
                    transaction.update(transQuery.docs.first.reference, {
                      'status': 'COMPLETED',
                    });
                  }
                });

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Payout approved")),
                  );
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text("Approve Request"),
            ),
          ],
        ],
      ),
    );
  }
}

Widget _buildWithdrawalDetailCard({
  required double amount,
  required String method,
  required String status,
  required String requestedBy,
  required String requestedAt,
  required String processedAt,
}) {
  final statusColor = status == 'Completed'
      ? Colors.green
      : status == 'Rejected'
          ? Colors.redAccent
          : Colors.orange;

  return Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.03),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: statusColor.withValues(alpha: 0.12),
              child: Icon(
                status == 'Pending'
                    ? Icons.hourglass_empty
                    : status == 'Completed'
                        ? Icons.check
                        : Icons.close,
                color: statusColor,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "₱${amount.toStringAsFixed(2)}",
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF342361),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      status,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildWithdrawalInfoRow("Method", method),
        _buildWithdrawalInfoRow("Requested By", requestedBy),
        _buildWithdrawalInfoRow("Requested At", requestedAt),
        _buildWithdrawalInfoRow("Processed At", processedAt),
      ],
    ),
  );
}

Widget _buildWithdrawalInfoRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Color(0xFF342361),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

// --- ADMIN GRANTS TAB ---
// --- ADMIN CONTENT MANAGEMENT TAB (GRANTS & ANNOUNCEMENTS) ---
class AdminContentManagement extends StatefulWidget {
  const AdminContentManagement({super.key});

  @override
  State<AdminContentManagement> createState() => _AdminContentManagementState();
}

class _AdminContentManagementState extends State<AdminContentManagement> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: Colors.white,
          child: TabBar(
            controller: _tabController,
            labelColor: const Color(0xFF4F378A),
            unselectedLabelColor: Colors.grey,
            indicatorColor: const Color(0xFF4F378A),
            tabs: const [
              Tab(icon: Icon(Icons.card_membership), text: "Featured Grants"),
              Tab(icon: Icon(Icons.announcement), text: "Announcements"),
              Tab(icon: Icon(Icons.fact_check), text: "Requirements"),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildGrantsSection(),
              _buildAnnouncementsSection(),
              _buildRequirementsSection(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGrantsSection() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Featured Grants", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                onPressed: () => _showAddGrantDialog(context),
                icon: const Icon(Icons.add),
                label: const Text("Add Grant"),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: !_adminFirebaseReady
                ? _buildPreviewGrants()
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('grants').snapshots(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                      var docs = snapshot.data!.docs;
                      if (docs.isEmpty) return const Center(child: Text("No grants found."));
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          var data = docs[index].data() as Map<String, dynamic>;
                          return _buildGrantTile(data, docs[index].id);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewGrants() {
    return Column(
      children: [
        _buildAdminPreviewBanner(),
        Expanded(
          child: ListView.builder(
            itemCount: _previewGrants.length,
            itemBuilder: (context, index) {
              final data = _previewGrants[index];
              return _buildGrantTile(data, "preview-$index", isPreview: true);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGrantTile(Map<String, dynamic> data, String id, {bool isPreview = false}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        title: Text(data['title'] ?? "Scholarship", style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text("${data['slots'] ?? 'N/A'} • ${data['benefit'] ?? 'N/A'}"),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: () {
            if (isPreview) {
              _showPreviewMessage(context, "Preview mode: cannot delete.");
            } else {
              FirebaseFirestore.instance.collection('grants').doc(id).delete();
            }
          },
        ),
      ),
    );
  }

  Widget _buildAnnouncementsSection() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Announcements", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                onPressed: () => _showAddAnnouncementDialog(context),
                icon: const Icon(Icons.add),
                label: const Text("Post New"),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: !_adminFirebaseReady
                ? _buildPreviewAnnouncements()
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('announcements').orderBy('timestamp', descending: true).snapshots(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                      var docs = snapshot.data!.docs;
                      if (docs.isEmpty) return const Center(child: Text("No announcements posted."));
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          var data = docs[index].data() as Map<String, dynamic>;
                          return _buildAnnouncementTile(data, docs[index].id);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequirementsSection() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Requirements", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                onPressed: () => _showCreateChecklistDialog(context),
                icon: const Icon(Icons.add),
                label: const Text("Create Checklist"),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: !_adminFirebaseReady
                ? _buildPreviewRequirements()
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('requirements_checklists').snapshots(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                      var docs = snapshot.data!.docs;
                      if (docs.isEmpty) return const Center(child: Text("No checklists found."));
                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          var data = docs[index].data() as Map<String, dynamic>;
                          return _buildChecklistTile(data, docs[index].id);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewRequirements() {
    return Column(
      children: [
        _buildAdminPreviewBanner(),
        const Center(child: Text("Requirements management preview", style: TextStyle(color: Colors.grey))),
      ],
    );
  }

  Widget _buildChecklistTile(Map<String, dynamic> data, String id) {
    List<dynamic> slots = data['slots'] ?? [];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        title: Text(data['title'] ?? "Checklist", style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text("${slots.length} document slots"),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: () => FirebaseFirestore.instance.collection('requirements_checklists').doc(id).delete(),
        ),
      ),
    );
  }

  Widget _buildPreviewAnnouncements() {
    return Column(
      children: [
        _buildAdminPreviewBanner(),
        const Center(child: Text("Sample announcements would appear here", style: TextStyle(color: Colors.grey))),
      ],
    );
  }

  Widget _buildAnnouncementTile(Map<String, dynamic> data, String id) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        title: Text(data['title'] ?? "Announcement", style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(data['description'] ?? "", maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: () => FirebaseFirestore.instance.collection('announcements').doc(id).delete(),
        ),
      ),
    );
  }

  void _showAddGrantDialog(BuildContext context) {
    final titleController = TextEditingController();
    final slotsController = TextEditingController();
    final benefitController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Add New Grant"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: titleController, decoration: const InputDecoration(labelText: "Grant Title")),
              TextField(controller: slotsController, decoration: const InputDecoration(labelText: "Slots/Target (e.g. 100 Slots)")),
              TextField(controller: benefitController, decoration: const InputDecoration(labelText: "Benefit (e.g. ₱15,000/Sem)")),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              if (titleController.text.isNotEmpty) {
                if (_adminFirebaseReady) {
                  await FirebaseFirestore.instance.collection('grants').add({
                    'title': titleController.text,
                    'slots': slotsController.text,
                    'benefit': benefitController.text,
                    'color': '0xFF4F378A',
                    'created_at': FieldValue.serverTimestamp(),
                  });
                  if (context.mounted) Navigator.pop(context);
                } else {
                  _showPreviewMessage(context, "Preview mode: cannot add.");
                }
              }
            },
            child: const Text("Add"),
          ),
        ],
      ),
    );
  }

  void _showAddAnnouncementDialog(BuildContext context) {
    final titleController = TextEditingController();
    final descController = TextEditingController();
    final tagController = TextEditingController(text: "NEWS");

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("New Announcement"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: titleController, decoration: const InputDecoration(labelText: "Title")),
              TextField(controller: descController, maxLines: 3, decoration: const InputDecoration(labelText: "Description")),
              TextField(controller: tagController, decoration: const InputDecoration(labelText: "Tag (e.g. NEWS, ADMIN, UPDATE)")),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              if (titleController.text.isNotEmpty) {
                if (_adminFirebaseReady) {
                  await FirebaseFirestore.instance.collection('announcements').add({
                    'title': titleController.text,
                    'description': descController.text,
                    'tag': tagController.text.toUpperCase(),
                    'timestamp': FieldValue.serverTimestamp(),
                  });
                  if (context.mounted) Navigator.pop(context);
                } else {
                  _showPreviewMessage(context, "Preview mode: cannot post.");
                }
              }
            },
            child: const Text("Post"),
          ),
        ],
      ),
    );
  }

  void _showCreateChecklistDialog(BuildContext context) {
    final titleController = TextEditingController();
    final List<TextEditingController> slotControllers = [TextEditingController()];

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Create Requirement Checklist"),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(
                      labelText: "Checklist Title",
                      hintText: "e.g. Freshman Admission",
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text("Document Slots", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  ...slotControllers.asMap().entries.map((entry) {
                    int idx = entry.key;
                    var controller = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              decoration: InputDecoration(
                                labelText: "Slot ${idx + 1}",
                                hintText: "e.g. COR",
                              ),
                            ),
                          ),
                          if (slotControllers.length > 1)
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                              onPressed: () {
                                setDialogState(() {
                                  slotControllers.removeAt(idx);
                                });
                              },
                            ),
                        ],
                      ),
                    );
                  }),
                  TextButton.icon(
                    onPressed: () {
                      setDialogState(() {
                        slotControllers.add(TextEditingController());
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text("Add Slot"),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                if (titleController.text.isNotEmpty && _adminFirebaseReady) {
                  List<String> slots = slotControllers
                      .map((c) => c.text.trim())
                      .where((text) => text.isNotEmpty)
                      .toList();
                  
                  await FirebaseFirestore.instance.collection('requirements_checklists').add({
                    'title': titleController.text.trim(),
                    'slots': slots,
                    'created_at': FieldValue.serverTimestamp(),
                  });
                  if (context.mounted) Navigator.pop(context);
                } else if (!_adminFirebaseReady) {
                  _showPreviewMessage(context, "Preview mode: cannot save.");
                }
              },
              child: const Text("Create"),
            ),
          ],
        ),
      ),
    );
  }
}

// --- UTILS ---
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  const SectionHeader({super.key, required this.title, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title, 
          style: TextStyle(
            fontSize: 18, 
            fontWeight: FontWeight.bold, 
            color: Theme.of(context).brightness == Brightness.dark 
                ? Colors.white.withValues(alpha: 0.9) 
                : const Color(0xFF342361)
          )
        ),
        TextButton(
          onPressed: onSeeAll, 
          child: Text(onSeeAll == null ? "" : "See All", style: const TextStyle(color: Color(0xFF4F378A)))
        ),
      ],
    );
  }
}

// --- SCHOLARSHIP DETAIL & APPLICATION VIEW ---
class ScholarshipDetailView extends StatelessWidget {
  final String title;
  final Color color;

  const ScholarshipDetailView({super.key, required this.title, required this.color});

  @override
  Widget build(BuildContext context) {
    String description = "This scholarship program is designed to provide financial assistance to qualified students.";
    List<String> benefits = [];
    List<String> requirements = [];

    // Additional fields for job-specific details
    String? submissionLocation;
    String? officeHours;
    String? availability;

    bool isJob = title.contains("Intern") || 
                title.contains("Crew") || 
                title.contains("Tutor") || 
                title.contains("Assistant") || 
                title.contains("Clerk") || 
                title.contains("Rider") || 
                title.contains("Staff") ||
                title.contains("Mod") ||
                title.contains("Promodizer");

    if (title.contains("Iskolar ng Bayan")) {
      description = "Automatic admission at free tuition para sa mga Public SHS graduates na nais mag-aral sa State Universities.";
      benefits = [
        "Automatic Admission sa SUCs",
        "Free Tuition Fee",
        "Miscellaneous Fees Support",
      ];
      requirements = [
        "Must be a Public SHS Graduate",
        "Not currently enrolled in UP",
        "Filipino Citizen",
      ];
    } else if (title.contains("Iskolar ni Gob")) {
      description = "Financial assistance para sa mga college students na taga-Rizal sa loob ng 3 taon o higit pa.";
      benefits = [
        "Financial Assistance: ₱5,000 per Semester",
        "SAP (Special Assistance Program)",
      ];
      requirements = [
        "Taga-Rizal (3+ years residency)",
        "College Student",
        "Family income below ₱350,000/year",
      ];
    } else if (title.contains("Iskolar ni Juan")) {
      description = "Program para sa mga nais kumuha ng Tech-Voc courses sa ilalim ng DSWD at PHINMA Education.";
      benefits = [
        "Free Tuition Fee",
        "Monthly Allowance sa partner schools",
      ];
      requirements = [
        "Interest in Tech-Voc courses",
        "Belongs to a low-income family",
      ];
    } else if (title.contains("Iskolar ng Dolores")) {
      description = "Educational assistance para sa mga college students na residente ng Barangay Dolores, Taytay.";
      benefits = ["Educational Assistance per Semester", "Financial Aid for school needs"];
      requirements = ["Residente ng Brgy. Dolores, Taytay", "Valid College Enrollment"];
    } else if (title.contains("Sta. Ana Skolar")) {
      description = "Financial aid program para sa mga masisipag na estudyante ng Barangay Sta. Ana, Taytay.";
      benefits = ["Financial Aid per Semester", "Support for Tuition/Books"];
      requirements = ["Residente ng Brgy. Sta. Ana, Taytay", "Good Academic Standing"];
    } else if (title.contains("Skolar ng Muzon")) {
      description = "Programang pang-edukasyon para sa mga kabataang residente ng Barangay Muzon, Taytay.";
      benefits = ["Financial Aid per Semester", "Educational Assistance"];
      requirements = ["Residente ng Brgy. Muzon, Taytay", "Actively Enrolled College Student"];
    } else if (title.contains("Skolar ng Taytay")) {
      description = "Ang pangunahing scholarship program ng LGU Taytay para sa lahat ng kwalipikadong kolehiyala sa bayan.";
      benefits = ["Financial Aid per Semester", "Mayor's Office Educational Support"];
      requirements = ["Residente ng Taytay, Rizal", "Qualified College Student"];
    } else if (title.contains("Summer Intern") || title.contains("Intern")) {
      description = "Gain valuable work experience with our summer internship program at leading tech companies.";
      benefits = ["Monthly Allowance: ₱15,000", "Certificate of Internship", "Hands-on Training"];
      requirements = ["Updated Resume / CV", "School ID Copy", "Enrollment Form", "Letter of Intent"];
      submissionLocation = "Municipal IT Office / PESO Office";
      officeHours = "8:00 AM - 5:00 PM (Monday to Friday)";
      availability = "Open to 3rd and 4th Year College Students";
    } else if (title.contains("Crew") || title.contains("Staff")) {
      description = "Join our energetic team and earn while on vacation. Perfect for students looking for flexible part-time work.";
      benefits = ["Daily Rate & Stipend", "Free Meals during shifts", "Flexible Schedule"];
      requirements = ["Biodata / Resume", "Barangay Clearance", "Working Permit (if minor)"];
      submissionLocation = "Municipal PESO Office";
      officeHours = "Walk-in: 9:00 AM - 4:00 PM";
      availability = "Students 18 years old and above";
    } else if (title.contains("Tutor")) {
      description = "Share your knowledge and help other students succeed while earning competitive hourly rates.";
      benefits = ["₱300 per Hour", "Flexible Online or In-person sessions", "Teaching Experience"];
      requirements = ["Latest Report Card", "Recommendation Letter", "Resume"];
      submissionLocation = "Municipal Library / Youth Center";
      officeHours = "By Appointment";
      availability = "College Students with GWA of 2.0 or higher";
    } else if (title.contains("Assistant") || title.contains("Mod")) {
      description = "Support administrative or specialized tasks in various environments like libraries or remote offices.";
      benefits = ["Competitive Pay", "Professional Environment", "Networking Opportunities"];
      requirements = ["Resume", "Copy of Grades", "Student ID"];
      submissionLocation = "Public Information Office / Brgy Hall";
      officeHours = "8:30 AM - 4:30 PM";
      availability = "Open for Senior High and College Students";
    } else if (title.contains("Clerk") || title.contains("Rider") || title.contains("Promodizer")) {
      description = "Flexible opportunities to earn extra income with project-based or commission-based work.";
      benefits = ["Pay based on output or sales", "Flexible hours", "Experience in retail or logistics"];
      requirements = ["Resume", "Valid ID", "NBI / Police Clearance"];
      submissionLocation = "Public Market Admin / PESO Office";
      officeHours = "9:00 AM - 5:00 PM";
      availability = "Students and Out-of-school Youth";
    } else {
      benefits = ["Financial subsidy for education", "Allowance for books and materials"];
      requirements = ["Valid Student ID", "Proof of Enrollment", "Good Academic Standing"];
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [color, color.withValues(alpha: 0.7)],
                  ),
                ),
                child: Center(
                  child: Icon(Icons.school, size: 80, color: Colors.white.withValues(alpha: 0.3)),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Description", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                  const SizedBox(height: 12),
                  Text(description, style: const TextStyle(color: Colors.black87, fontSize: 15, height: 1.6)),
                  const SizedBox(height: 32),
                  
                  const Text("Benefits", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                  const SizedBox(height: 16),
                  ...benefits.map((benefit) => _buildPointItem(benefit, Icons.stars, color)),
                  const SizedBox(height: 32),
                  
                  Text(isJob ? "Document Needs" : "Requirements", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                  const SizedBox(height: 16),
                  ...requirements.map((req) => _buildPointItem(req, Icons.check_circle_outline, color)),
                  
                  if (isJob) ...[
                    const SizedBox(height: 32),
                    const Text("Submission Details", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                    const SizedBox(height: 16),
                    _buildPointItem("Submit at: ${submissionLocation ?? 'Municipal Hall'}", Icons.location_on, color),
                    _buildPointItem("Office Hours: ${officeHours ?? '8:00 AM - 5:00 PM'}", Icons.access_time, color),
                    const SizedBox(height: 32),
                    const Text("Eligibility", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                    const SizedBox(height: 16),
                    _buildPointItem(availability ?? "Open for all students", Icons.person_outline, color),
                  ],

                  const SizedBox(height: 48),
                  
                  if (!isJob)
                    ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => ApplicationFormView(title: title)),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: color,
                        minimumSize: const Size(double.infinity, 64),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        elevation: 0,
                      ),
                      child: const Text("Apply", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPointItem(String text, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 16),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15, height: 1.4))),
        ],
      ),
    );
  }
}

class ApplicationFormView extends StatefulWidget {
  final String title;
  const ApplicationFormView({super.key, required this.title});

  @override
  State<ApplicationFormView> createState() => _ApplicationFormViewState();
}

class _ApplicationFormViewState extends State<ApplicationFormView> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _gwaController = TextEditingController();
  final _incomeController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      if (doc.exists && mounted) {
        setState(() {
          _nameController.text = doc.get('full_name') ?? "";
        });
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _gwaController.dispose();
    _incomeController.dispose();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location services are disabled.')));
      }
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permissions are denied')));
        }
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permissions are permanently denied.')));
      }
      return;
    } 

    try {
      Position position = await Geolocator.getCurrentPosition();
      List<Placemark> placemarks = await placemarkFromCoordinates(position.latitude, position.longitude);
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks[0];
        String address = "${place.street}, ${place.subLocality}, ${place.locality}, ${place.administrativeArea}";
        _addressController.text = address;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error fetching location: $e')));
      }
    }
  }

  bool get _isJob => widget.title.contains("Intern") || 
                widget.title.contains("Crew") || 
                widget.title.contains("Tutor") || 
                widget.title.contains("Assistant") || 
                widget.title.contains("Clerk") || 
                widget.title.contains("Rider") || 
                widget.title.contains("Staff") ||
                widget.title.contains("Mod") ||
                widget.title.contains("Promodizer");

  @override
  Widget build(BuildContext context) {
    final isJob = _isJob;

    return Scaffold(
      appBar: AppBar(title: Text(isJob ? "Job Application" : "Grant Application")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Applying for:", style: TextStyle(color: Colors.grey[600])),
              Text(widget.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
              const SizedBox(height: 32),
              
              if (isJob) ...[
                _buildFormInput("Full Name", "Enter your complete name", Icons.person_outline, controller: _nameController),
                const SizedBox(height: 24),
                _buildFormInputWithUpload(
                  label: "Resume / CV", 
                  hint: "", 
                  icon: Icons.description,
                  uploadTitle: "Updated Resume (PDF/JPG)",
                  uploadSubtitle: "Required for application",
                  showTextField: false,
                  isUploaded: globalUploads.containsKey("Resume") || globalUploads.values.any((v) => v['name'].toLowerCase().contains('resume')),
                ),
                _buildFormInput("Primary Skills", "e.g. Graphic Design, Typing, etc.", Icons.stars),
                const SizedBox(height: 24),
                _buildFormInput("Contact Number", "e.g. 09123456789", Icons.phone),
                const SizedBox(height: 24),
                _buildFormInput("Home Address", "Enter your current residence", Icons.location_on_outlined, 
                  controller: _addressController,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.my_location, color: Color(0xFF4F378A)),
                    onPressed: _getCurrentLocation,
                  ),
                ),
              ] else ...[
                _buildFormInput("Full Name", "Name as shown on official records", Icons.person_outline, controller: _nameController),
                const SizedBox(height: 24),
                _buildFormInput("Date of Birth", "MM/DD/YYYY", Icons.cake_outlined),
                const SizedBox(height: 24),
                _buildFormInput("Contact Number", "e.g. 09123456789", Icons.phone),
                const SizedBox(height: 24),
                _buildFormInput("Home Address", "Enter your complete address", Icons.location_on_outlined,
                  controller: _addressController,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.my_location, color: Color(0xFF4F378A)),
                    onPressed: _getCurrentLocation,
                  ),
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 32),
                const Text("Required Documents & Info", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                const SizedBox(height: 24),

                if (widget.title.contains("Bayan")) ...[
                  _buildFormInputWithUpload(
                    label: "GWA Score", 
                    hint: "Enter your SHS general average", 
                    icon: Icons.grade,
                    uploadTitle: "Grade 12 Report Card",
                    uploadSubtitle: "Final SHS Grades",
                    isUploaded: globalUploads.containsKey("Grade 12 Report Card (1st Sem)") || globalUploads.values.any((v) => v['name'].toLowerCase().contains('card')),
                    controller: _gwaController,
                  ),
                  _buildFormInputWithUpload(
                    label: "Annual Family Income", 
                    hint: "Total yearly household income", 
                    icon: Icons.money,
                    uploadTitle: "ITR / Affidavit of Income",
                    uploadSubtitle: "Proof of financial status",
                    isUploaded: globalUploads.containsKey("Certificate of Indigency"),
                    controller: _incomeController,
                  ),
                  _buildFormInputWithUpload(
                    label: "Diploma Status", 
                    hint: "Public SHS School Name", 
                    icon: Icons.school,
                    uploadTitle: "SHS Diploma / Graduation Cert",
                    uploadSubtitle: "Proof of eligibility",
                    isUploaded: globalUploads.containsKey("Scholarship Certification"),
                  ),
                ] else if (widget.title.contains("Gob")) ...[
                  _buildFormInputWithUpload(
                    label: "Residency Years", 
                    hint: "How many years in Rizal?", 
                    icon: Icons.timer,
                    uploadTitle: "Voter's ID / Parent's Voter Cert",
                    uploadSubtitle: "Proof of 3+ years residency",
                    isUploaded: globalUploads.containsKey("Government ID / Passport"),
                  ),
                  _buildFormInputWithUpload(
                    label: "GWA Score", 
                    hint: "Previous semester average", 
                    icon: Icons.grade,
                    uploadTitle: "Transcript of Records",
                    uploadSubtitle: "Official grade summary",
                    isUploaded: globalUploads.containsKey("Transcript of Records"),
                    controller: _gwaController,
                  ),
                  _buildFormInputWithUpload(
                    label: "Social Status", 
                    hint: "Number of siblings in school", 
                    icon: Icons.people,
                    uploadTitle: "Certificate of Indigency",
                    uploadSubtitle: "Issued by Barangay / DSWD",
                    isUploaded: globalUploads.containsKey("Certificate of Indigency"),
                    controller: _incomeController,
                  ),
                ] else if (widget.title.contains("Juan")) ...[
                  _buildFormInput("Tech-Voc Interest", "e.g. Shielded Metal Arc Welding", Icons.settings_suggest),
                  const SizedBox(height: 24),
                  _buildFormInputWithUpload(
                    label: "Barangay Record", 
                    hint: "Barangay Name", 
                    icon: Icons.house,
                    uploadTitle: "Barangay Clearance",
                    uploadSubtitle: "Proof of good standing",
                    isUploaded: globalUploads.containsKey("Barangay Clearance"),
                  ),
                  _buildFormInputWithUpload(
                    label: "Age Verification", 
                    hint: "Current Age", 
                    icon: Icons.badge,
                    uploadTitle: "PSA Birth Certificate",
                    uploadSubtitle: "Official birth record",
                    isUploaded: globalUploads.containsKey("PSA Birth Certificate"),
                  ),
                ] else if (widget.title.contains("Dolores") || widget.title.contains("Ana") || widget.title.contains("Muzon")) ...[
                  _buildFormInputWithUpload(
                    label: "Barangay Residency", 
                    hint: "Street / Phase Name", 
                    icon: Icons.location_city,
                    uploadTitle: "Certificate of Residency",
                    uploadSubtitle: "Barangay specific residency",
                    isUploaded: globalUploads.containsKey("Certificate of Indigency"),
                  ),
                  _buildFormInputWithUpload(
                    label: "Current GWA", 
                    hint: "Last semester grades", 
                    icon: Icons.auto_graph,
                    uploadTitle: "Report Card",
                    uploadSubtitle: "Most recent academic record",
                    isUploaded: globalUploads.containsKey("Grade 11 Report Card") || globalUploads.containsKey("Grade 12 Report Card (1st Sem)"),
                    controller: _gwaController,
                  ),
                  _buildFormInputWithUpload(
                    label: "Enrollment Proof", 
                    hint: "Course & Year Level", 
                    icon: Icons.history_edu,
                    uploadTitle: "Registration Form",
                    uploadSubtitle: "Current semester COM/SER",
                    isUploaded: globalUploads.values.any((v) => v['name'].toLowerCase().contains('registration') || v['name'].toLowerCase().contains('enrollment')),
                  ),
                ] else ...[
                  // Default for Skolar ng Taytay and others
                  _buildFormInputWithUpload(
                    label: "GWA Score", 
                    hint: "Enter your general average", 
                    icon: Icons.grade,
                    uploadTitle: "Summary of Grades",
                    uploadSubtitle: "Proof of academic standing",
                    isUploaded: globalUploads.containsKey("Grade 11 Report Card") || globalUploads.containsKey("Grade 12 Report Card (1st Sem)") || globalUploads.containsKey("Transcript of Records"),
                    controller: _gwaController,
                  ),
                  _buildFormInputWithUpload(
                    label: "Annual Family Income", 
                    hint: "Enter total annual income", 
                    icon: Icons.money,
                    uploadTitle: "ITR / Indigency",
                    uploadSubtitle: "Proof of Family Income",
                    isUploaded: globalUploads.containsKey("Certificate of Indigency") || globalUploads.containsKey("PSA Birth Certificate"),
                    controller: _incomeController,
                  ),
                  _buildFormInputWithUpload(
                    label: "Community Status", 
                    hint: "Are you a Taytay resident?", 
                    icon: Icons.verified_user,
                    uploadTitle: "Voter's Certification",
                    uploadSubtitle: "Required for LGU grants",
                    isUploaded: globalUploads.containsKey("Government ID / Passport"),
                  ),
                ],

                const SizedBox(height: 24),
                _buildFormInput("Course Enrolled", "e.g. BS Information Technology", Icons.book),
              ],
              
              const SizedBox(height: 32),
              
              const SizedBox(height: 48),
              
              ElevatedButton(
                onPressed: _isSubmitting ? null : _handleSubmit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F378A),
                  minimumSize: const Size(double.infinity, 64),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                child: _isSubmitting 
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text("Submit Application", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFormInputWithUpload({
    required String label,
    required String hint,
    required IconData icon,
    required String uploadTitle,
    required String uploadSubtitle,
    bool showTextField = true,
    bool isUploaded = false,
    TextEditingController? controller,
  }) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: isDark ? Colors.white10 : Colors.grey[200]!),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isDark ? Colors.white : const Color(0xFF1A1A1A))),
              const Text(" *", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          if (showTextField) ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: controller,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 14),
                prefixIcon: Icon(icon, size: 22, color: const Color(0xFF4F378A)),
                filled: true,
                fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF3EDFF).withValues(alpha: 0.3),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 18),
              ),
              validator: (value) => value!.isEmpty ? "Please enter the $label" : null,
            ),
            const SizedBox(height: 20),
            const Divider(height: 1),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: isDark ? Colors.white10 : const Color(0xFFF3EDFF), shape: BoxShape.circle),
                child: const Icon(Icons.file_upload_outlined, color: Color(0xFF4F378A), size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(uploadTitle, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    Text(isUploaded ? "Uploaded from Vault" : uploadSubtitle, style: TextStyle(fontSize: 11, color: isUploaded ? Colors.green : (isDark ? Colors.white38 : Colors.black38))),
                  ],
                ),
              ),
              Icon(isUploaded ? Icons.check_circle : Icons.error_outline, color: isUploaded ? Colors.green : Colors.orange, size: 24),
            ],
          ),
          if (!isUploaded)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                "Go to Document Vault to upload this requirement.",
                style: TextStyle(fontSize: 10, color: isDark ? Colors.orange[300] : Colors.orange[800], fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFormInput(String label, String hint, IconData icon, {TextEditingController? controller, Widget? suffixIcon}) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? Colors.white : const Color(0xFF1A1A1A))),
            const Text(" *", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 14),
            prefixIcon: Icon(icon, size: 22, color: const Color(0xFF4F378A)),
            suffixIcon: suffixIcon,
            filled: true,
            fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white,
            errorStyle: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isDark ? Colors.white10 : Colors.grey[200]!)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: isDark ? Colors.white10 : Colors.grey[200]!)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF4F378A), width: 1.5)),
            errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.redAccent, width: 1.5)),
          ),
          validator: (value) => value!.isEmpty ? "Mandatory: Please provide this information" : null,
        ),
      ],
    );
  }

  Future<void> _handleSubmit() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isSubmitting = true);
      
      final user = FirebaseAuth.instance.currentUser;
      
      // Automatically gather matching documents from the Vault for this submission
      Map<String, dynamic> attachedDocs = {};
      
      // Define requirement keys based on the grant type
      List<String> requiredVaultKeys = [];
      if (widget.title.contains("Bayan")) {
        requiredVaultKeys = ["Grade 12 Report Card (1st Sem)", "Certificate of Indigency", "Scholarship Certification"];
      } else if (widget.title.contains("Gob")) {
        requiredVaultKeys = ["Government ID / Passport", "Transcript of Records", "Certificate of Indigency"];
      } else if (widget.title.contains("Juan")) {
        requiredVaultKeys = ["Barangay Clearance", "PSA Birth Certificate"];
      } else {
        requiredVaultKeys = ["Grade 11 Report Card", "Grade 12 Report Card (1st Sem)", "Transcript of Records", "Certificate of Indigency", "Government ID / Passport"];
      }

      // Collect the actual file data from globalUploads
      for (var key in requiredVaultKeys) {
        if (globalUploads.containsKey(key)) {
          attachedDocs[key] = globalUploads[key];
        }
      }
      
      // Save application to Firestore with the "auto-uploaded" documents
      await FirebaseFirestore.instance.collection('applications').add({
        'user_id': user?.uid,
        'grant_title': widget.title,
        'status': 'PENDING',
        'attached_documents': attachedDocs, // Documents from vault are now sent here
        'timestamp': FieldValue.serverTimestamp(),
        'applicant_name': _nameController.text.trim(),
        'address': _addressController.text.trim(),
        'gwa': _gwaController.text.trim(),
        'income': _incomeController.text.trim(),
      });

      // Add a local notification trigger simulation
      globalNotifications.insert(0, AppNotification(
        title: "Application Received",
        body: "Your application for ${widget.title} with ${attachedDocs.length} attached documents from your vault has been submitted successfully.",
        timestamp: DateTime.now(),
      ));

      if (context.mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Success!"),
            content: Text(_isJob 
              ? "Your application has been submitted. Documents from your vault have been attached. Please wait for a call from our team."
              : "Your application and vault documents have been submitted to the scholarship office."),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context); // Close dialog
                  Navigator.pop(context); // Back to details
                  Navigator.pop(context); // Back to home
                },
                child: const Text("OK"),
              ),
            ],
          ),
        );
      }
    }
  }
}
