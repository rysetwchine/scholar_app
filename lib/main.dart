import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();
final FlutterTts flutterTts = FlutterTts();

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

// Helper function to play the congratulatory voice message
Future<void> speakCongratulations() async {
  await flutterTts.setLanguage("en-US");
  await flutterTts.setPitch(1.0);
  await flutterTts.speak(
    "Congratulations Scholar! You have successfully passed the examination and are now officially qualified for the scholarship grant. Please wait for your scholarship allowance to be processed. You will automatically receive another notification once the money has been successfully added to your wallet.",
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();

  // Load the app first so the user doesn't see a white screen
  runApp(const MyApp());

  // Initialize Firebase and Notifications in the background
  _initializeBackend();
}

Future<void> _initializeBackend() async {
  try {
    await Firebase.initializeApp();

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
    debugPrint("Backend initialization error: $e");
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Scholarship Management',
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
      home: const SplashScreen(),
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
    // Wait for splash screen time
    await Future.delayed(const Duration(seconds: 5));
    
    if (mounted) {
      try {
        // Ensure Firebase is initialized before checking user
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp();
        }
        
        if (!mounted) return;

        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const MainNavigationWrapper()),
          );
        } else {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const SignUpView()),
          );
        }
      } catch (e) {
        // If Firebase fails, still go to SignUp/Login so user can see something
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
    return Scaffold(
      backgroundColor: const Color(0xFFF3EDFF),
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
                        border: Border.all(color: const Color(0xFF4F378A), width: 4),
                      ),
                    ),
                    const Icon(Icons.school, size: 70, color: Color(0xFF4F378A)),
                    Positioned(
                      bottom: 10,
                      right: 15,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Color(0xFF4F378A),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check, size: 14, color: Colors.white),
                      ),
                    )
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  "iSKOLAR",
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    color: Color(0xFF342361),
                  ),
                ),
                const Text(
                  "— GRANT —",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    color: Color(0xFF4F378A),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 100),
            const CircularProgressIndicator(
              color: Color(0xFF4F378A),
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
        navigator.pushReplacement(
          MaterialPageRoute(builder: (context) => const MainNavigationWrapper()),
        );
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
    return Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Header Image Placeholder (Simulating the student image)
            Container(
              width: double.infinity,
              height: 300,
              decoration: const BoxDecoration(
                color: Color(0xFFF3EDFF),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(40),
                  bottomRight: Radius.circular(40),
                ),
              ),
              child: const Center(
                child: Icon(Icons.person_pin, size: 180, color: Color(0xFF4F378A)),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Welcome Back!",
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Color(0xFF342361)),
                  ),
                  const Text(
                    "Log in to your account",
                    style: TextStyle(color: Colors.black54, fontSize: 14),
                  ),
                  const SizedBox(height: 32),

                  // Student/Admin Toggle
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => setState(() => _isStudentLogin = true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isStudentLogin ? const Color(0xFF4F378A) : const Color(0xFFF3EDFF),
                            foregroundColor: _isStudentLogin ? Colors.white : const Color(0xFF4F378A),
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
                            backgroundColor: !_isStudentLogin ? const Color(0xFF4F378A) : const Color(0xFFF3EDFF),
                            foregroundColor: !_isStudentLogin ? Colors.white : const Color(0xFF4F378A),
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
                      child: const Text(
                        "Forgot password?",
                        style: TextStyle(color: Color(0xFF4F378A), fontWeight: FontWeight.bold),
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
                        const Text("Don't have an account? ", style: TextStyle(color: Colors.black54)),
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const SignUpView()),
                            );
                          },
                          child: const Text(
                            "Sign up",
                            style: TextStyle(color: Color(0xFF4F378A), fontWeight: FontWeight.bold),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1A1A1A))),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.black26, fontSize: 16),
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(icon, color: Colors.black38, size: 24),
            ),
            suffixIcon: isPassword
              ? Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF342361), size: 24),
                    onPressed: onToggleVisibility,
                  ),
                )
              : null,
            filled: true,
            fillColor: const Color(0xFFF3EDFF).withValues(alpha: 0.5),
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
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(backgroundColor: Colors.white, elevation: 0, iconTheme: const IconThemeData(color: Color(0xFF342361))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Create Account", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
            const Text("Join the iSKOLAR community", style: TextStyle(color: Colors.black54, fontSize: 16)),
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
                  const Text("Already have an account? ", style: TextStyle(color: Colors.black54)),
                  GestureDetector(
                    onTap: _handleLogin,
                    child: const Text(
                      "Login",
                      style: TextStyle(color: Color(0xFF4F378A), fontWeight: FontWeight.bold),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1A1A1A))),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFFF3EDFF).withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFF342361)),
              style: const TextStyle(color: Colors.black87, fontSize: 16),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1A1A1A))),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.black26, fontSize: 16),
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(icon, color: Colors.black38, size: 24),
            ),
            suffixIcon: isPassword
              ? Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF342361), size: 24),
                    onPressed: onToggleVisibility,
                  ),
                )
              : null,
            filled: true,
            fillColor: const Color(0xFFF3EDFF).withValues(alpha: 0.5),
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

  final List<Widget> _screens = [
    const HomeView(),
    const ExamStatusView(),
    const RequirementsView(),
    const WithdrawView(),
    const DigitalIDView(),
    const SettingsView(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _selectedIndex == 0 ? const DocumentChecklistDrawer() : null,
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
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text("Scholarship Hub"),
            leading: Builder(builder: (context) {
              return IconButton(
                icon: const Icon(Icons.fact_check_outlined),
                onPressed: () => Scaffold.of(context).openDrawer(),
              );
            }),
            actions: [
              IconButton(
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
              const Padding(
                padding: EdgeInsets.only(right: 16.0),
                child: CircleAvatar(radius: 18, backgroundColor: Color(0xFF4F378A), child: Icon(Icons.person, color: Colors.white, size: 20)),
              )
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text("Welcome back, $name!", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
              Text("Scholarship ID: $scholarId", style: const TextStyle(color: Colors.black54, fontSize: 13)),
              const SizedBox(height: 30),

          // Application Status Card
          const SectionHeader(title: "Current Application"),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFFCBBEE4).withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF4F378A).withValues(alpha: 0.1)),
            ),
            child: Row(
              children: [
                const Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 50,
                      height: 50,
                      child: CircularProgressIndicator(value: 0.75, strokeWidth: 6, color: Color(0xFF482F7D), backgroundColor: Colors.white),
                    ),
                    Text("3/4", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ],
                ),
                const SizedBox(width: 20),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Renewal Processing", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text("Verification of Grades (Stage 3)", style: TextStyle(color: Colors.black54, fontSize: 12)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Color(0xFF4F378A)),
              ],
            ),
          ),

          const SizedBox(height: 30),

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
          const SectionHeader(title: "Featured Grants"),
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                // 1. Bagong Pilipinas Merit (From image)
                _buildFeaturedCard(
                  "Bagong Pilipinas Merit",
                  "Incoming 1st Year | GWA 95%",
                  "Up to ₱120,000 / Year",
                  const Color(0xFF1A237E), // Deep Blue
                ),
                // 2. CHED Merit (From image)
                _buildFeaturedCard(
                  "CHED Merit Program",
                  "1st Year | GWA 93%+",
                  "Up to ₱120,000 / Year",
                  const Color(0xFFC62828), // Red
                ),
                // 3. CHED COSCHO (From image)
                _buildFeaturedCard(
                  "CHED COSCHO",
                  "Incoming & Current | GWA 80%",
                  "₱80,000 - ₱115,000 / AY",
                  const Color(0xFF2E7D32), // Green
                ),
                // 4. ACEF-GIAHEP (From image)
                _buildFeaturedCard(
                  "ACEF-GIAHEP",
                  "Priority Programs",
                  "₱40,000 - ₱60,000 / Year",
                  const Color(0xFFEF6C00), // Orange
                ),
                // 5. UNIFEST-TES (From image)
                _buildFeaturedCard(
                  "CHED UNIFEST-TES",
                  "Ongoing Undergrads",
                  "₱20,000 - ₱27,000 / Year",
                  const Color(0xFF6A1B9A), // Purple
                ),
                
                // Keep the database items as well
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance.collection('grants').snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const SizedBox();
                    var docs = snapshot.data!.docs;
                    return Row(
                      children: docs.map((doc) {
                        var data = doc.data() as Map<String, dynamic>;
                        return _buildFeaturedCard(
                          data['title'] ?? "Scholarship",
                          data['slots'] ?? "Ongoing",
                          data['benefit'] ?? "Financial Aid",
                          Color(int.parse(data['color'] ?? "0xFF4F378A")),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 30),

          // Announcements Section
          const SectionHeader(title: "Application Updates"),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('applications')
                  .where('user_id', isEqualTo: user?.uid)
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _buildAnnouncementCard(
                        context,
                        "Welcome Scholar!",
                        "Apply for your first scholarship to see real-time updates here.",
                        "Today",
                        const Color(0xFF4F378A),
                      ),
                      _buildAnnouncementCard(
                        context,
                        "CHED Alert",
                        "CHED Merit applications for 2026 are now officially open.",
                        "June 1, 2026",
                        Colors.blue,
                      ),
                    ],
                  );
                }

                return ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: snapshot.data!.docs.length,
                  itemBuilder: (context, index) {
                    var data = snapshot.data!.docs[index].data() as Map<String, dynamic>;
                    String title = data['grant_title'] ?? "Scholarship";
                    String status = data['status'] ?? "PENDING";
                    Timestamp? ts = data['timestamp'] as Timestamp?;
                    String date = ts != null 
                        ? "${ts.toDate().day}/${ts.toDate().month}/${ts.toDate().year}" 
                        : "Processing";

                    Color statusColor = status == "PENDING" ? Colors.amber : 
                                      status == "PASSED" ? Colors.green : Colors.red;

                    return _buildAnnouncementCard(
                      context,
                      title,
                      "Your application for $title is currently: $status",
                      date,
                      statusColor,
                      "UPDATE",
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
  },
);
  }

  void _showEligibilityAlert(String title, bool forFirstYearOnly) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28),
            SizedBox(width: 10),
            Text("Not Eligible", style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text("This '$title' grant is only available for ${forFirstYearOnly ? 'Incoming 1st Year Students' : 'Current College Students'}. Please check other available opportunities."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Color(0xFF4F378A), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildFeaturedCard(String title, String slots, String benefit, Color color) {
    return Container(
      width: 260,
      margin: const EdgeInsets.only(right: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.2), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(slots, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          const Spacer(),
          Text(benefit, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () {
              // Corrected eligibility logic to match card descriptions
              bool isMerit = title.contains("Merit");
              
              if (isMerit && !_isIncomingFirstYear) {
                // Merit is for 1st Years only
                _showEligibilityAlert(title, true);
              } else if (title.contains("UNIFEST") && _isIncomingFirstYear) {
                // TES/UNIFEST is usually for ongoing students
                _showEligibilityAlert(title, false);
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ScholarshipDetailView(
                      title: title,
                      color: color,
                    ),
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: color,
              minimumSize: const Size(double.infinity, 36),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text("Apply Now", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildGrantItem(String title, String target, String benefit, Color color, IconData icon) {
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
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey[200]!),
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
                  Text(target, style: const TextStyle(color: Colors.black54, fontSize: 11)),
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
          color: color.withValues(alpha: 0.1),
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
            Text(title, style: TextStyle(color: color.withValues(alpha: 0.8), fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(desc, style: const TextStyle(color: Colors.black54, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
            const Spacer(),
            Text(date, style: const TextStyle(color: Colors.black38, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// --- 2. EXAM STATUS VIEW ---
class ExamStatusView extends StatelessWidget {
  const ExamStatusView({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FF),
      appBar: AppBar(
        title: const Text("Exam Dashboard"),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).snapshots(),
        builder: (context, userSnapshot) {
          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('applications')
                .where('user_id', isEqualTo: user?.uid)
                .snapshots(),
            builder: (context, appSnapshot) {
              String name = "Student";
              String scholarId = "N/A";
              String course = "Not Set";
              
              if (userSnapshot.hasData && userSnapshot.data!.exists) {
                var userData = userSnapshot.data!.data() as Map<String, dynamic>;
                name = userData['full_name'] ?? "Student";
                scholarId = userData['scholar_number'] ?? "N/A";
                course = userData['course'] ?? "Not Set";
              }

              String status = "PENDING";
              String examDate = "May 20, 2026";
              String room = "204";
              String building = "B";
              String seat = "23";
              String time = "8:00 AM";
              String address = "ICCT Colleges - Sumulong Highway, Cainta, Rizal";

              if (appSnapshot.hasData && appSnapshot.data!.docs.isNotEmpty) {
                var appData = appSnapshot.data!.docs.first.data() as Map<String, dynamic>;
                status = (appData['status'] ?? "PENDING").toUpperCase();
                // Optionally override defaults if data exists in Firestore
              }

              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // 1. Exam Status Card
                  _buildDashboardCard(
                    title: "Exam Status",
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
                                color: const Color(0xFFFFF8E1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                status,
                                style: const TextStyle(
                                  color: Color(0xFFFBC02D),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            Text(
                              examDate,
                              style: const TextStyle(color: Colors.black38, fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          "Scholarship Qualifying Exam",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF342361),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 2. Results Summary Card
                  _buildDashboardCard(
                    title: "Results Summary",
                    icon: Icons.bar_chart_outlined,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        "Results are not yet published.",
                        style: TextStyle(color: Colors.black26, fontSize: 14),
                      ),
                    ),
                  ),

                  // 3. Exam Details & Location Card
                  _buildDashboardCard(
                    title: "Exam Details & Location",
                    icon: Icons.location_on_outlined,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildDetailItem("Room", room),
                            _buildDetailItem("Building", building),
                            _buildDetailItem("Seat", seat),
                            _buildDetailItem("Time", time),
                          ],
                        ),
                        const SizedBox(height: 20),
                        const Divider(),
                        const SizedBox(height: 16),
                        const Text("Testing Center Address:", style: TextStyle(color: Colors.black26, fontSize: 11)),
                        const SizedBox(height: 8),
                        Text(
                          address,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Color(0xFF342361),
                          ),
                        ),
                        const SizedBox(height: 20),
                        
                        // Mini Map Preview
                        GestureDetector(
                          onTap: () async {
                            final Uri url = Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}');
                            if (!await launchUrl(url)) {
                              debugPrint("Could not launch $url");
                            }
                          },
                          child: Container(
                            height: 150,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F3F4), // Map background color
                              borderRadius: BorderRadius.circular(16),
                              image: const DecorationImage(
                                image: NetworkImage('https://maps.googleapis.com/maps/api/staticmap?center=ICCT+Colleges+Sumulong+Highway&zoom=15&size=600x300&markers=color:red%7CICCT+Colleges+Sumulong+Highway&key=YOUR_API_KEY'), 
                                fit: BoxFit.cover,
                                onError: null,
                              ),
                            ),
                            child: Stack(
                              children: [
                                // Realistic Map Background Simulation (Fallback)
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
                            final Uri url = Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}');
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
                    title: "Scholar Information",
                    icon: Icons.school_outlined,
                    child: Column(
                      children: [
                        _buildInfoRow("Scholar No", scholarId),
                        const SizedBox(height: 12),
                        _buildInfoRow("Name", name.toLowerCase()),
                        const SizedBox(height: 12),
                        _buildInfoRow("Course", course),
                      ],
                    ),
                  ),

                  // 5. Requirements Status Card
                  _buildDashboardCard(
                    title: "Requirements Status",
                    icon: Icons.description_outlined,
                    child: Column(
                      children: [
                        _buildRequirementRow("Report Card", "Completed", Colors.green, Icons.check_circle),
                        const SizedBox(height: 12),
                        _buildRequirementRow("Birth Certificate", "Completed", Colors.green, Icons.check_circle),
                        const SizedBox(height: 12),
                        _buildRequirementRow("Income Certificate", "Pending", Colors.orange, Icons.hourglass_empty),
                      ],
                    ),
                  ),

                  // 6. Scholarship Qualification Card
                  _buildDashboardCard(
                    title: "Scholarship Qualification",
                    icon: Icons.emoji_events_outlined,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text("Status:", style: TextStyle(color: Colors.black26, fontSize: 14)),
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3EDFF),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                "Eligible for Scholarship",
                                style: TextStyle(color: Color(0xFF342361), fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(Icons.refresh, size: 18, color: Color(0xFF342361)),
                            const SizedBox(width: 8),
                            RichText(
                              text: const TextSpan(
                                style: TextStyle(color: Color(0xFF342361), fontSize: 14),
                                children: [
                                  TextSpan(text: "Next Step: ", style: TextStyle(fontWeight: FontWeight.bold)),
                                  TextSpan(text: "For Final Interview"),
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

  Widget _buildDashboardCard({required String title, required IconData icon, required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
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
              Icon(icon, size: 20, color: const Color(0xFF342361)),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Color(0xFF342361),
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

  Widget _buildDetailItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.black26, fontSize: 11)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: Color(0xFF342361),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.black26, fontSize: 14)),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: Color(0xFF342361),
          ),
        ),
      ],
    );
  }

  Widget _buildRequirementRow(String label, String status, Color color, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF342361))),
        const Spacer(),
        Text(status, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
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
  // Track uploaded files
  final Map<String, Map<String, dynamic>?> _uploadedFiles = {};

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
          child: const Row(
            children: [
              Icon(Icons.cloud_done_outlined, color: Color(0xFF4F378A)),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Vault Security Active", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text("Your personal documents are encrypted and stored safely.", style: TextStyle(fontSize: 12, color: Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
        const Text("Folders", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF342361))),
        const SizedBox(height: 16),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 1.5,
          children: [
            _buildFolderCard("Certificates", "4 items", Colors.blue, Icons.workspace_premium),
            _buildFolderCard("IDs", "2 items", Colors.orange, Icons.badge),
            _buildFolderCard("Grades", "12 items", Colors.green, Icons.grade),
            _buildFolderCard("Others", "0 items", Colors.grey, Icons.more_horiz),
          ],
        ),
        const SizedBox(height: 30),
        const Text("Recent Uploads", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF342361))),
        const SizedBox(height: 12),
        _buildDocCard("My_Resumes_2026.pdf"),
        _buildDocCard("Passport_Scan.jpg"),
      ],
    );
  }

  Widget _buildFolderCard(String name, String count, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey[100]!),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 28),
          const Spacer(),
          Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          Text(count, style: const TextStyle(fontSize: 11, color: Colors.black38)),
        ],
      ),
    );
  }


  Widget _buildDocCard(String title) {
    final file = _uploadedFiles[title];
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey[100]!)),
      child: Row(
        children: [
          Icon(file != null ? Icons.check_circle : Icons.description_outlined, color: file != null ? Colors.green : Colors.grey, size: 30),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(file != null ? file['name'] : "No file uploaded", style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          ),
          if (file == null)
            TextButton(onPressed: () => _showUploadModal(title), child: const Text("Upload"))
          else
            IconButton(onPressed: () => setState(() => _uploadedFiles[title] = null), icon: const Icon(Icons.delete_outline, color: Colors.redAccent))
        ],
      ),
    );
  }

  void _showUploadModal(String docTitle) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => UploadModal(
        docTitle: docTitle,
        onComplete: (fileData) {
          setState(() => _uploadedFiles[docTitle] = fileData);
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

  void _startUpload() async {
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
      'name': "${widget.docTitle.replaceAll(' ', '_').toLowerCase()}.pdf",
      'size': "2.4 MB"
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
            _sourceItem(Icons.photo_library_outlined, "Gallery"),
            _sourceItem(Icons.camera_alt_outlined, "Camera"),
            _sourceItem(Icons.cloud_outlined, "Cloud Drive"),
          ],
        ),
      ),
    );
  }

  Widget _sourceItem(IconData icon, String label) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF4F378A)),
      title: Text(label),
      onTap: () {
        Navigator.pop(context); // Close menu
        _startUpload(); // Start progress
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

  @override
  Widget build(BuildContext context) {
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
        child: _buildCurrentStep(),
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_step) {
      case 0: return _buildStepA();
      case 1: return _buildStepB();
      case 2: return _buildStepC();
      default: return const SizedBox();
    }
  }

  // PART A: Balance & Amount
  Widget _buildStepA() {
    final user = FirebaseAuth.instance.currentUser;
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).snapshots(),
      builder: (context, snapshot) {
        double balance = 0.0;
        if (snapshot.hasData && snapshot.data!.exists) {
          balance = (snapshot.data!.get('wallet_balance') ?? 0.0).toDouble();
        }

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
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  prefixText: "₱ ",
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF4F378A), width: 2)),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                children: ["500", "1,000", "5,000"].map((val) => ActionChip(
                  label: Text("₱$val"),
                  onPressed: () => _amountController.text = val.replaceAll(",", ""),
                  backgroundColor: Colors.grey[100],
                )).toList(),
              ),
              const SizedBox(height: 40),
              ElevatedButton(
                onPressed: () => setState(() => _step = 1),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4F378A),
                    minimumSize: const Size(double.infinity, 55),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16))),
                child: const Text("Withdraw Now",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      },
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
    return GestureDetector(
      onTap: () => setState(() { _step = 2; }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey[200]!),
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
  Widget _buildStepC() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          _buildInput("Account Name"),
          const SizedBox(height: 16),
          _buildInput("Student ID"),
          const Spacer(),
          ElevatedButton(
            onPressed: () async {
              final user = FirebaseAuth.instance.currentUser;
              final amount = double.tryParse(_amountController.text) ?? 0.0;

              if (amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Enter a valid amount")));
                return;
              }

              // Save to Firestore
              await FirebaseFirestore.instance.collection('withdrawals').add({
                'user_id': user?.uid,
                'amount': amount,
                'method': 'Selected Method',
                'timestamp': FieldValue.serverTimestamp(),
                'status': 'Pending',
              });

              if (mounted) {
                setState(() => _step = 0);
                _amountController.clear();
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const TransactionHistoryView()),
                );
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Withdrawal Request Submitted")));
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F378A), minimumSize: const Size(double.infinity, 55), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
            child: const Text("Confirm & Submit", style: TextStyle(color: Colors.white)),
          )
        ],
      ),
    );
  }

  Widget _buildInput(String label) {
    return TextField(
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
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

        if (snapshot.hasData && snapshot.data!.exists) {
          var data = snapshot.data!.data() as Map<String, dynamic>;
          name = (data['full_name'] ?? name).toUpperCase();
          scholarId = data['scholar_number'] ?? scholarId;
          course = "${data['year_level'] ?? 'N/A'} - ${data['course'] ?? 'N/A'}";
        }

        return Scaffold(
          appBar: AppBar(title: const Text("Digital ID")),
          body: Center(
            child: Container(
              width: 300,
              height: 500,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [BoxShadow(color: accentColor.withValues(alpha: 0.2), blurRadius: 30, spreadRadius: 5)],
                border: Border.all(color: accentColor.withValues(alpha: 0.3), width: 2),
              ),
              child: Column(
                children: [
                  const Text("SCHOLARSHIP PORTAL", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: accentColor)),
                  const SizedBox(height: 20),
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      shape: BoxShape.circle,
                      border: Border.all(color: accentColor, width: 3),
                    ),
                    child: const Icon(Icons.person, size: 80, color: Colors.grey),
                  ),
                  const SizedBox(height: 20),
                  Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                  Text(course, style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 10),
                  Text("ID: $scholarId", style: const TextStyle(fontWeight: FontWeight.bold, color: accentColor)),
                  const Spacer(),
                  // Placeholder for QR
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(border: Border.all(color: Colors.black12), borderRadius: BorderRadius.circular(16)),
                    child: const Icon(Icons.qr_code_2, size: 100),
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
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).snapshots(),
      builder: (context, snapshot) {
        String name = "Juan Dela Cruz";
        String email = user?.email ?? "student@scholar.app";

        if (snapshot.hasData && snapshot.data!.exists) {
          name = snapshot.data!.get('full_name') ?? name;
        }

        return Scaffold(
          appBar: AppBar(title: const Text("Settings")),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 20),
            children: [
              Center(
                child: Column(
                  children: [
                    const CircleAvatar(radius: 50, backgroundColor: Color(0xFF4F378A), child: Icon(Icons.person, size: 60, color: Colors.white)),
                    const SizedBox(height: 12),
                    Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    Text(email, style: const TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              _buildSettingItem("Edit Profile", Icons.person_outline),
              _buildToggleItem("Notification Push", true),
              _buildToggleItem("Scholar Alert Sound", isScholarAlertEnabled, (v) {
                setState(() {
                  isScholarAlertEnabled = v;
                });
              }),
              _buildSettingItem("Theme Preferences", Icons.palette_outlined),
              const Divider(indent: 20, endIndent: 20),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text("SECURITY", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              _buildToggleItem("Biometric Log-in", true),
              _buildSettingItem("Change Password", Icons.lock_outline),
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

  Widget _buildSettingItem(String title, IconData icon) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF4F378A)),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () {},
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

class DocumentChecklistDrawer extends StatelessWidget {
  const DocumentChecklistDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Color(0xFF4F378A)),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.folder_shared, color: Colors.white, size: 48),
                  SizedBox(height: 12),
                  Text("Document Checklist", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text("Common files needed for most scholarship applications:", style: TextStyle(color: Colors.black54, fontSize: 13)),
          ),
          _buildCheckItem("ITR of Parents / Affidavit"),
          _buildCheckItem("Certificate of Indigency"),
          _buildCheckItem("Certified True Copy of Grades"),
          _buildCheckItem("GWA Certification"),
          _buildCheckItem("Good Moral Certificate"),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(20),
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50), backgroundColor: const Color(0xFF4F378A)),
              child: const Text("Got it!", style: TextStyle(color: Colors.white)),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildCheckItem(String title) {
    return CheckboxListTile(
      value: false,
      onChanged: (v) {},
      title: Text(title, style: const TextStyle(fontSize: 14)),
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: const Color(0xFF4F378A),
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

                  _buildInfoRow(Icons.calendar_today_outlined, date),
                  _buildInfoRow(Icons.access_time, "Office Hours (8:00 AM - 5:00 PM)"),
                  _buildInfoRow(Icons.location_on_outlined, "Scholarship Office / Online"),

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

  Widget _buildInfoRow(IconData icon, String text) {
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
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
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
            .collection('withdrawals')
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
              final amount = (data['amount'] ?? 0.0).toDouble();
              final status = data['status'] ?? 'Pending';
              final timestamp = data['timestamp'] as Timestamp?;
              final dateStr = timestamp != null
                  ? "${timestamp.toDate().day}/${timestamp.toDate().month}/${timestamp.toDate().year}"
                  : "Today";

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey[100]!),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.outbound, color: Colors.redAccent, size: 20),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("Withdrawal Request", style: TextStyle(fontWeight: FontWeight.bold)),
                          Text(dateStr, style: const TextStyle(color: Colors.black38, fontSize: 11)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text("-₱${amount.toStringAsFixed(2)}",
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
                        Text(status,
                            style: TextStyle(
                                color: status == 'Completed' ? Colors.green : Colors.orange,
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
                await FirebaseAuth.instance.signOut();
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
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Settings',
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
      case 3: return const AdminGrantsManagement();
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
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: 1.1, // Fixed: Increased height to prevent overflow
          children: [
            _buildStatCard("Total Scholars", "1,245", Icons.people, Colors.blue),
            _buildStatCard("Pending Apps", "48", Icons.assignment, Colors.orange),
            _buildStatCard("Pending Payouts", "12", Icons.payments, Colors.green),
            _buildStatCard("Active Grants", "8", Icons.campaign, Colors.purple),
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
              onPressed: () {},
              child: const Text("View All", style: TextStyle(color: Color(0xFF4F378A))),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildActivityTile(
          "Juan Dela Cruz submitted a new application",
          "2 minutes ago",
          Icons.person_add_alt_1_outlined,
          Colors.blue,
        ),
        _buildActivityTile(
          "GCash Payout processed for Maria Clara",
          "1 hour ago",
          Icons.account_balance_wallet_outlined,
          Colors.green,
        ),
        _buildActivityTile(
          "New Grant 'GT REAP STEM' published",
          "3 hours ago",
          Icons.campaign_outlined,
          Colors.purple,
        ),
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

  Widget _buildActivityTile(String title, String time, IconData icon, Color color) {
    return Container(
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
    );
  }
}

// --- ADMIN SCHOLAR DETAIL VIEW ---
class AdminScholarDetailView extends StatefulWidget {
  final DocumentSnapshot scholarDoc;
  const AdminScholarDetailView({super.key, required this.scholarDoc});

  @override
  State<AdminScholarDetailView> createState() => _AdminScholarDetailViewState();
}

class _AdminScholarDetailViewState extends State<AdminScholarDetailView> {
  late TextEditingController _balanceController;

  @override
  void initState() {
    super.initState();
    _balanceController = TextEditingController(
      text: (widget.scholarDoc.get('wallet_balance') ?? 0.0).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    var data = widget.scholarDoc.data() as Map<String, dynamic>;
    
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
              await FirebaseFirestore.instance.collection('users').doc(widget.scholarDoc.id).update({
                'wallet_balance': newBalance,
              });
              if (mounted) {
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
class AdminScholarsList extends StatelessWidget {
  const AdminScholarsList({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('users').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        var docs = snapshot.data!.docs;

        return ListView.builder(
          padding: const EdgeInsets.all(24),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            var doc = docs[index];
            var data = doc.data() as Map<String, dynamic>;
            double balance = (data['wallet_balance'] ?? 0.0).toDouble();

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 5)
                ],
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFF4F378A).withValues(alpha: 0.1),
                  child: const Icon(Icons.person, color: Color(0xFF4F378A)),
                ),
                title: Text(
                  data['full_name'] ?? "No Name",
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF342361)),
                ),
                subtitle: Text(
                  "${data['scholar_number'] ?? 'No ID'} • ${data['year_level'] ?? 'N/A'}",
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      "₱${balance.toStringAsFixed(2)}",
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                    ),
                    const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                  ],
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => AdminScholarDetailView(scholarDoc: doc),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

// --- ADMIN APPLICATIONS TAB ---
class AdminApplicationsList extends StatelessWidget {
  const AdminApplicationsList({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('applications').orderBy('timestamp', descending: true).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        var docs = snapshot.data!.docs;

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.assignment_outlined, size: 64, color: Colors.grey[300]),
                const SizedBox(height: 16),
                const Text("No applications to review", style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(24),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            var data = docs[index].data() as Map<String, dynamic>;
            String status = data['status'] ?? "PENDING";
            
            return Container(
              margin: const EdgeInsets.only(bottom: 20),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
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
                        child: Text(
                          data['grant_title'] ?? "Unknown Grant",
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF342361)),
                        ),
                      ),
                      _buildStatusBadge(status),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.person_outline, size: 14, color: Colors.grey),
                      const SizedBox(width: 8),
                      Text("User ID: ${data['user_id']}", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (status == "PENDING")
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => FirebaseFirestore.instance.collection('applications').doc(docs[index].id).update({'status': 'FAILED'}),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                              side: const BorderSide(color: Colors.red),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text("Reject", style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              await FirebaseFirestore.instance.collection('applications').doc(docs[index].id).update({'status': 'PASSED'});
                              globalNotifications.insert(0, AppNotification(
                                title: "Grant Approved!",
                                body: "Your application for ${data['grant_title']} has been approved.",
                                timestamp: DateTime.now(),
                              ));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Application Approved")));
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            child: const Text("Approve", style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    )
                  else
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text("Decision Finalized", style: TextStyle(color: Colors.black26, fontSize: 12, fontStyle: FontStyle.italic)),
                        SizedBox(width: 8),
                        Icon(Icons.check_circle_outline, size: 16, color: Colors.black12),
                      ],
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildStatusBadge(String status) {
    Color color = Colors.orange;
    if (status == "PASSED") color = Colors.green;
    if (status == "FAILED") color = Colors.red;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        status,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }
}

// --- ADMIN WITHDRAWALS TAB ---
class AdminWithdrawalsList extends StatelessWidget {
  const AdminWithdrawalsList({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('withdrawals').orderBy('timestamp', descending: true).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        var docs = snapshot.data!.docs;

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

        return ListView.builder(
          padding: const EdgeInsets.all(24),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            var data = docs[index].data() as Map<String, dynamic>;
            String status = data['status'] ?? "Pending";
            double amount = (data['amount'] ?? 0.0).toDouble();

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
                trailing: status == "Pending" ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.redAccent),
                      onPressed: () => FirebaseFirestore.instance.collection('withdrawals').doc(docs[index].id).update({'status': 'Rejected'}),
                    ),
                    IconButton(
                      icon: const Icon(Icons.check, color: Colors.green),
                      onPressed: () => FirebaseFirestore.instance.collection('withdrawals').doc(docs[index].id).update({'status': 'Completed'}),
                    ),
                  ],
                ) : null,
              ),
            );
          },
        );
      },
    );
  }
}

// --- ADMIN GRANTS TAB ---
class AdminGrantsManagement extends StatelessWidget {
  const AdminGrantsManagement({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Manage Grants", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                onPressed: () => _showAddGrantDialog(context),
                icon: const Icon(Icons.add),
                label: const Text("New Grant"),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('grants').snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                var docs = snapshot.data!.docs;
                
                if (docs.isEmpty) {
                  return const Center(child: Text("No grants found. Click 'New Grant' to add one."));
                }

                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    var data = docs[index].data() as Map<String, dynamic>;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        title: Text(data['title'] ?? "Scholarship"),
                        subtitle: Text("${data['slots'] ?? 'N/A'} • ${data['benefit'] ?? 'N/A'}"),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                          onPressed: () => FirebaseFirestore.instance.collection('grants').doc(docs[index].id).delete(),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          )
        ],
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: titleController, decoration: const InputDecoration(labelText: "Grant Title")),
            TextField(controller: slotsController, decoration: const InputDecoration(labelText: "Slots/Target (e.g. 100 Slots)")),
            TextField(controller: benefitController, decoration: const InputDecoration(labelText: "Benefit (e.g. ₱50,000/Year)")),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              if (titleController.text.isNotEmpty) {
                await FirebaseFirestore.instance.collection('grants').add({
                  'title': titleController.text,
                  'slots': slotsController.text,
                  'benefit': benefitController.text,
                  'color': '0xFF4F378A',
                });
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text("Add"),
          ),
        ],
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
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
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

    if (title.contains("Bagong Pilipinas Merit")) {
      benefits = [
        "Annual Financial Assistance up to ₱120,000 (Private HEIs)",
        "Annual Financial Assistance up to ₱80,000 (SUCs)",
        "Full Tuition and Miscellaneous Fees",
      ];
      requirements = [
        "Must have a GWA of at least 95%",
        "Must be a Filipino Citizen",
        "Incoming 1st Year College Student",
      ];
    } else if (title.contains("CHED Merit")) {
      benefits = [
        "Full Merit: ₱120,000/year (Private) / ₱80,000 (State)",
        "Half Merit: ₱60,000/year (Private) / ₱40,000 (State)",
        "Book Allowance and Stipend",
      ];
      requirements = [
        "Must have a GWA of at least 93%",
        "Family income must not exceed ₱500k",
        "Incoming 1st Year College Student",
      ];
    } else if (title.contains("COSCHO")) {
      benefits = [
        "Regular Allowance: ₱80,000 per AY",
        "Other Allowances (Thesis/OJT/Laptop): ₱115,000 per AY",
      ];
      requirements = [
        "Must have a GWA of at least 80%",
        "Family income must not exceed ₱300k",
        "Incoming & Current College Students",
      ];
    } else if (title.contains("ACEF-GIAHEP")) {
      benefits = [
        "Private HEIs: ₱60,000 per year",
        "SUCs/LUCs: ₱40,000 per year",
      ];
      requirements = [
        "Must enroll in CHED priority programs (Agriculture, Forestry, Fisheries, etc.)",
        "Family income must not exceed ₱400k",
      ];
    } else if (title.contains("UNIFEST-TES") || title.contains("TES")) {
      benefits = [
        "Private HEIs: ₱27,000 per year",
        "SUCs/LUCs: ₱20,000 per year",
        "₱10,000/AY for PWDs",
        "₱8,000 one-time grant for Board/Licensure Exam takers",
      ];
      requirements = [
        "Applicants must be Filipino Citizen",
        "Enrolled in CHED-recognized institution",
        "Ongoing College Students / Undergrads",
      ];
    } else if (title.contains("DOST")) {
      benefits = [
        "Full Tuition Subsidy (up to ₱40,000/year)",
        "Monthly Living Allowance (₱7,000)",
        "Book Allowance (₱10,000/year)",
      ];
      requirements = [
        "Must be a STEM student",
        "Must be in the top 5% of graduating class",
        "Must pass the DOST-SEI Examination",
      ];
    } else if (title.contains("GT REAP")) {
      benefits = [
        "Brand New High-End Laptop",
        "Monthly Internet & Living Allowance",
        "Direct Hire for IT Internships",
      ];
      requirements = [
        "3rd or 4th Year IT/CS Students",
        "Must have a GWA of 2.0 or better",
        "Actively enrolled in priority HEIs",
      ];
    } else if (title.contains("Gawad Talino")) {
      benefits = [
        "Medical School Tuition Support",
        "Hospital Internship Slots",
        "Post-Graduation Hospital Placement",
      ];
      requirements = [
        "Health & Pharmacy related courses",
        "No failing grades in major subjects",
      ];
    } else if (title.contains("LGU Assistance")) {
      benefits = [
        "₱5,000 - ₱10,000 Semesterly Subsidy",
        "Uniform & School Supply Allowance",
      ];
      requirements = [
        "Must be a bonafide resident of the city",
        "Active Voter or child of a registered voter",
      ];
    } else if (title.contains("Intern")) {
      description = "Gain valuable work experience with our summer internship program at leading tech companies.";
      benefits = ["Monthly Allowance: ₱15,000", "Certificate of Internship", "Hands-on Training"];
      requirements = ["Currently enrolled in a relevant degree", "Good communication skills", "Available for at least 8 weeks"];
    } else if (title.contains("Crew") || title.contains("Staff")) {
      description = "Join our energetic team and earn while on vacation. Perfect for students looking for flexible part-time work.";
      benefits = ["Daily Rate & Stipend", "Free Meals during shifts", "Flexible Schedule"];
      requirements = ["At least 18 years old", "Active and enthusiastic", "Can work weekends"];
    } else if (title.contains("Tutor")) {
      description = "Share your knowledge and help other students succeed while earning competitive hourly rates.";
      benefits = ["₱300 per Hour", "Flexible Online or In-person sessions", "Teaching Experience"];
      requirements = ["Strong academic background", "Patience and passion for teaching", "Good grades in subject of choice"];
    } else if (title.contains("Assistant") || title.contains("Mod")) {
      description = "Support administrative or specialized tasks in various environments like libraries or remote offices.";
      benefits = ["Competitive Pay", "Professional Environment", "Networking Opportunities"];
      requirements = ["Organized and detail-oriented", "Proficient in basic computer tasks", "Available part-time"];
    } else if (title.contains("Clerk") || title.contains("Rider") || title.contains("Promodizer")) {
      description = "Flexible opportunities to earn extra income with project-based or commission-based work.";
      benefits = ["Pay based on output or sales", "Flexible hours", "Experience in retail or logistics"];
      requirements = ["Reliable and honest", "Good time management", "Necessary tools (e.g., smartphone, vehicle)"];
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
                  
                  const Text("Requirements", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
                  const SizedBox(height: 16),
                  ...requirements.map((req) => _buildPointItem(req, Icons.check_circle_outline, color)),
                  const SizedBox(height: 48),
                  
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
  bool _isSubmitting = false;

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
                _buildFormInputWithUpload(
                  label: "Resume / CV", 
                  hint: "", 
                  icon: Icons.description,
                  uploadTitle: "Updated Resume (PDF/JPG)",
                  uploadSubtitle: "Required for application",
                  showTextField: false,
                ),
                _buildFormInput("Primary Skills", "e.g. Graphic Design, Typing, etc.", Icons.stars),
                const SizedBox(height: 24),
                _buildFormInput("Contact Number", "e.g. 09123456789", Icons.phone),
              ] else ...[
                _buildFormInputWithUpload(
                  label: "GWA Score", 
                  hint: "Enter your general average (e.g. 95.0)", 
                  icon: Icons.grade,
                  uploadTitle: "Report Card / Summary of Grades",
                  uploadSubtitle: "Proof of GWA Score",
                ),

                _buildFormInputWithUpload(
                  label: "Annual Family Income", 
                  hint: "Enter total annual income (e.g. 300000)", 
                  icon: Icons.money,
                  uploadTitle: "ITR / Certificate of Indigency",
                  uploadSubtitle: "Proof of Family Income",
                ),

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
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
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
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1A1A1A))),
              const Text(" *", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          if (showTextField) ...[
            const SizedBox(height: 16),
            TextFormField(
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: Colors.black26, fontSize: 14),
                prefixIcon: Icon(icon, size: 22, color: const Color(0xFF4F378A)),
                filled: true,
                fillColor: const Color(0xFFF3EDFF).withValues(alpha: 0.3),
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
                decoration: const BoxDecoration(color: Color(0xFFF3EDFF), shape: BoxShape.circle),
                child: const Icon(Icons.file_upload_outlined, color: Color(0xFF4F378A), size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(uploadTitle, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    Text(uploadSubtitle, style: const TextStyle(fontSize: 11, color: Colors.black38)),
                  ],
                ),
              ),
              const Icon(Icons.check_circle, color: Colors.green, size: 24),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFormInput(String label, String hint, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1A1A1A))),
            const Text(" *", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.black26, fontSize: 14),
            prefixIcon: Icon(icon, size: 22, color: const Color(0xFF4F378A)),
            filled: true,
            fillColor: Colors.white,
            errorStyle: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey[200]!)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Colors.grey[200]!)),
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
      
      // Save application to Firestore
      await FirebaseFirestore.instance.collection('applications').add({
        'user_id': user?.uid,
        'grant_title': widget.title,
        'status': 'PENDING',
        'timestamp': FieldValue.serverTimestamp(),
      });

      // Add a local notification trigger simulation
      globalNotifications.insert(0, AppNotification(
        title: "Application Received",
        body: "Your application for ${widget.title} has been submitted successfully.",
        timestamp: DateTime.now(),
      ));

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Success!"),
            content: Text(_isJob 
              ? "Your application has been submitted. Please wait for a call from our team for your interview schedule."
              : "Your application has been submitted and is now being processed."),
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
