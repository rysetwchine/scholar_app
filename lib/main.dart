import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
  final _scholarController = TextEditingController();
  final _passwordController = TextEditingController();

  Future<void> _handleLogin() async {
    if (_scholarController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill in all fields")),
      );
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
                  const SizedBox(height: 40),

                  // Scholar Number Field
                  _buildInputField(
                    label: "Scholar Number",
                    hint: "Enter your scholar number",
                    icon: Icons.person_outline,
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
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF342361))),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          obscureText: obscureText,
          onSubmitted: (_) {
            if (isPassword) {
              _handleLogin(); // Trigger login if enter is pressed on password field
            }
          },
          textInputAction: isPassword ? TextInputAction.done : TextInputAction.next,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.black26, fontSize: 14),
            prefixIcon: Icon(icon, color: Colors.black38, size: 22),
            suffixIcon: isPassword
              ? IconButton(
                  icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF342361), size: 22),
                  onPressed: onToggleVisibility,
                )
              : null,
            filled: true,
            fillColor: const Color(0xFFF3EDFF),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 20),
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
        'wallet_balance': 0.0,
        'year_level': 'Not Set',
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
      appBar: AppBar(backgroundColor: Colors.white, elevation: 0),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Create Account", style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
            const Text("Join the iSKOLAR community", style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 32),

            _buildInputField(label: "Full Name", hint: "Enter your full name", icon: Icons.person_outline, controller: _nameController),
            const SizedBox(height: 20),
            _buildInputField(label: "Scholar Number", hint: "e.g. 2026-10045", icon: Icons.badge_outlined, controller: _scholarController),
            const SizedBox(height: 20),
            _buildInputField(label: "Email Address", hint: "Enter your email", icon: Icons.email_outlined, controller: _emailController),
            const SizedBox(height: 20),
            _buildInputField(
              label: "Password", 
              hint: "Create a password", 
              icon: Icons.lock_outline, 
              isPassword: true, 
              obscureText: _obscurePassword,
              controller: _passwordController,
              onToggleVisibility: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
            const SizedBox(height: 20),
            _buildInputField(label: "Confirm Password", hint: "Repeat password", icon: Icons.lock_reset, isPassword: true, obscureText: _obscurePassword, controller: _confirmPasswordController),
            
            const SizedBox(height: 40),

            ElevatedButton(
              onPressed: _isLoading ? null : _handleSignUp,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F378A),
                minimumSize: const Size(double.infinity, 60),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: _isLoading 
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text("Sign Up", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            
            const SizedBox(height: 24),
            Center(
              child: TextButton(
                onPressed: _handleLogin,
                child: const Text("Already have an account? Login", style: TextStyle(color: Color(0xFF4F378A))),
              ),
            ),
            const SizedBox(height: 40),
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
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF342361))),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          obscureText: obscureText,
          onSubmitted: (_) {
            if (isPassword) {
              _handleSignUp(); // Trigger signup if enter is pressed on password field
            }
          },
          textInputAction: isPassword ? TextInputAction.done : TextInputAction.next,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.black26, fontSize: 14),
            prefixIcon: Icon(icon, color: Colors.black38, size: 22),
            suffixIcon: isPassword
              ? IconButton(
                  icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF342361), size: 22),
                  onPressed: onToggleVisibility,
                )
              : null,
            filled: true,
            fillColor: const Color(0xFFF3EDFF),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 20),
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
    const SecurityCenterView(),
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
          BottomNavigationBarItem(icon: Icon(Icons.shield_outlined), activeIcon: Icon(Icons.shield), label: 'Security'),
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
            height: 200,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('grants').snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                
                var docs = snapshot.data!.docs;
                if (docs.isEmpty) {
                  return Center(
                    child: Text("No grants available", style: TextStyle(color: Colors.grey[400])),
                  );
                }

                return ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    var data = docs[index].data() as Map<String, dynamic>;
                    return _buildFeaturedCard(
                      data['title'] ?? "Scholarship",
                      data['slots'] ?? "Ongoing",
                      data['benefit'] ?? "Financial Aid",
                      Color(int.parse(data['color'] ?? "0xFF4F378A")),
                    );
                  },
                );
              },
            ),
          ),

          const SizedBox(height: 30),

          // Announcements Section
          const SectionHeader(title: "Latest News"),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildAnnouncementCard(context, "System Update", "New features added to the wallet.", "June 1, 2026", Colors.indigo),
                _buildAnnouncementCard(context, "Maintenance", "Server maintenance on June 5th.", "May 28, 2026", Colors.purple),
              ],
            ),
          ),

          const SizedBox(height: 30),

          // Available Grants List
          const SectionHeader(title: "Available Opportunities"),
          const SizedBox(height: 12),
          _buildGrantItem("GT REAP STEM", "3rd-4th Year IT Students", "Laptop + Allowance", Colors.blue, Icons.computer),
          _buildGrantItem("Gawad Talino", "Health & Pharmacy", "Medical Assistance", Colors.orange, Icons.medication),
        ],
      ),
    );
  },
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
            onPressed: () {},
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
    return Container(
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
    );
  }

  Widget _buildAnnouncementCard(BuildContext context, String title, String desc, String date, Color color) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const AnnouncementDetailView()),
        );
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
              child: const Text("NEWS", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
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
      appBar: AppBar(title: const Text("Exam Status")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('applications')
            .where('user_id', isEqualTo: user?.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          var docs = snapshot.data!.docs;

          if (docs.isEmpty) {
            return const Center(
              child: Text("No applications found.", style: TextStyle(color: Colors.grey)),
            );
          }

          var data = docs.first.data() as Map<String, dynamic>;
          String status = (data['status'] ?? "PENDING").toUpperCase();
          bool isPassed = status == "PASSED";

          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              // 1. HEADER (STATUS CARD)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF4F378A), Color(0xFF342361)]),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(color: const Color(0xFF4F378A).withValues(alpha: 0.3), blurRadius: 15, offset: const Offset(0, 8))],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Current Standing:", style: TextStyle(color: Colors.white70, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(
                      isPassed ? "QUALIFIED / PASSED" : "Processing Application",
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Your application for '${data['grant_title'] ?? 'Scholarship'}' is currently ${status.toLowerCase()}.",
                      style: const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),
              const SectionHeader(title: "Application Timeline"),
              const SizedBox(height: 16),

              // 2. THE TIMELINE (VERTICAL STEPPER)
              _buildStep("Application Submitted", data['date'] ?? "May 15, 2026", true),
              _buildStep("Document Verification", "Completed", true),
              _buildStep("Examination", isPassed ? "Passed" : "Pending - June 01, 2026", true, isLast: false),
              _buildStep("Interview", "To Be Determined", isPassed, isLast: false),
              _buildStep("Final Result", "TBD", isPassed, isLast: true),

              const SizedBox(height: 32),

              // 3. QUICK INFO BOX
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF4F378A).withValues(alpha: 0.1)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.info_outline, color: Color(0xFF4F378A), size: 20),
                        SizedBox(width: 10),
                        Text("Important Reminders", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ],
                    ),
                    const Divider(height: 24),
                    _buildInfoItem(Icons.location_on_outlined, "Venue", data['location'] ?? "ICCT Building, Room 302"),
                    const SizedBox(height: 12),
                    _buildInfoItem(Icons.assignment_outlined, "Bring", "Valid ID, Exam Permit, Black Pen"),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStep(String title, String subtitle, bool isDone, {bool isLast = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: isDone ? const Color(0xFF4F378A) : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF4F378A), width: 2),
              ),
              child: isDone ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 40,
                color: isDone ? const Color(0xFF4F378A) : Colors.grey[300],
              ),
          ],
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: isDone ? const Color(0xFF342361) : Colors.grey)),
            Text(subtitle, style: TextStyle(fontSize: 12, color: isDone ? Colors.black54 : Colors.grey[400])),
          ],
        ),
      ],
    );
  }

  Widget _buildInfoItem(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.black38),
        const SizedBox(width: 12),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(color: Colors.black87, fontSize: 13),
              children: [
                TextSpan(text: "$label: ", style: const TextStyle(fontWeight: FontWeight.bold)),
                TextSpan(text: value),
              ],
            ),
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

class _RequirementsViewState extends State<RequirementsView> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _selectedScholarship = "Bagong Pilipinas Merit";

  // Track uploaded files
  final Map<String, Map<String, dynamic>?> _uploadedFiles = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Online Requirements"),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF4F378A),
          labelColor: const Color(0xFF4F378A),
          tabs: const [Tab(text: "New Application"), Tab(text: "Renewal")],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildRequirementList(true),
          _buildRequirementList(false),
        ],
      ),
    );
  }

  Widget _buildRequirementList(bool isNew) {
    final docs = isNew
        ? ["Transcript of Records", "Good Moral Character", "Income Tax Return (ITR)"]
        : ["Transcript of Records", "Certificate of Enrollment", "Latest GWA Certification"];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text("Choose Scholarship Type", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey[200]!)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedScholarship,
              isExpanded: true,
              items: ["Bagong Pilipinas Merit", "GT REAP STEM", "Gawad Talino"].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (val) => setState(() => _selectedScholarship = val!),
            ),
          ),
        ),
        const SizedBox(height: 30),
        ...docs.map((doc) => _buildDocCard(doc)),
        const SizedBox(height: 40),
        if (docs.every((d) => _uploadedFiles[d] != null))
          ElevatedButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Application submitted successfully!")));
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4F378A),
              minimumSize: const Size(double.infinity, 60),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text("SUBMIT APPLICATION", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
      ],
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
              child: Container(
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
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F378A), minimumSize: const Size(double.infinity, 55), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                child: const Text("Next", style: TextStyle(color: Colors.white)),
              )
            ],
          ),
        );
      }
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
          _buildInput("Account Number"),
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
                  const Text("VALID UNTIL JUNE 2026", style: TextStyle(fontSize: 10, color: Colors.black26)),
                ],
              ),
            ),
          ),
        );
      }
    );
  }
}

// --- 6. SECURITY CENTER VIEW ---
class SecurityCenterView extends StatelessWidget {
  const SecurityCenterView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Security Center")),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
            child: const Row(
              children: [
                Icon(Icons.gpp_maybe, color: Colors.redAccent, size: 32),
                SizedBox(width: 16),
                Expanded(child: Text("Stay alert! We will never ask for your PIN via SMS or Call.", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
              ],
            ),
          ),
          const SizedBox(height: 30),
          const SectionHeader(title: "Common Security Threats"),
          const SizedBox(height: 16),
          _buildSecurityAlert("Spam Call Warning", "Reports of fake scholarship officers calling students to ask for processing fees.", Icons.call_end),
          _buildSecurityAlert("Phishing SMS", "SMS claiming you won a bonus prize. Do not click any links.", Icons.sms_failed),
          _buildSecurityAlert("Account Safety", "Ensure biometric login is enabled in settings for extra protection.", Icons.lock_person),
        ],
      ),
    );
  }

  Widget _buildSecurityAlert(String title, String desc, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(border: Border.all(color: Colors.grey[200]!), borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.indigo, size: 20),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          Text(desc, style: const TextStyle(color: Colors.black54, fontSize: 13)),
        ],
      ),
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
                    await FirebaseAuth.instance.signOut();
                    if (context.mounted) {
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(builder: (context) => const LoginView()),
                        (route) => false,
                      );
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
  const AnnouncementDetailView({super.key});

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
                  // Circular background for the logo
                  Container(
                    width: 120,
                    height: 120,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const Icon(Icons.school, size: 80, color: Color(0xFF1E1B4B)),
                  // Simulated books/shield decoration
                  Positioned(
                    bottom: 20,
                    right: 40,
                    child: Column(
                      children: [
                        Container(width: 40, height: 8, decoration: BoxDecoration(color: Colors.red[400], borderRadius: BorderRadius.circular(4))),
                        const SizedBox(height: 4),
                        Container(width: 50, height: 8, decoration: BoxDecoration(color: Colors.orange[400], borderRadius: BorderRadius.circular(4))),
                      ],
                    ),
                  )
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Schedule Tag
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text("Schedule", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ),

                  const SizedBox(height: 20),
                  const Text(
                    "Midterm Exam Schedule",
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF342361)),
                  ),

                  const SizedBox(height: 24),

                  // Info rows
                  _buildInfoRow(Icons.calendar_today_outlined, "May 15, 2025"),
                  _buildInfoRow(Icons.access_time, "9:00 AM - 12:00 PM"),
                  _buildInfoRow(Icons.location_on_outlined, "New Company, Building A"),

                  const SizedBox(height: 32),

                  const Text(
                    "This is an announcement that the Midterm Examinations will be conducted on May 20, 2025. Students are advised to be at the venue 30 minutes before the scheduled time. Please bring your student ID and necessary writing materials.",
                    style: TextStyle(color: Colors.black87, height: 1.6, fontSize: 15),
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

// --- UTILS ---
class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF342361))),
        TextButton(onPressed: () {}, child: const Text("See All", style: TextStyle(color: Color(0xFF4F378A)))),
      ],
    );
  }
}
