import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:signature/signature.dart';
import 'package:file_saver/file_saver.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:collection/collection.dart';
import 'package:universal_html/html.dart' as html;


//==============================================================================
// 1. CORE APPLICATION STRUCTURE & THEME
//==============================================================================

// --- Theme Colors ---
const Color primaryColor = Color(0xFFFFA000); // Amber
const Color darkBackgroundColor = Color(0xFF121212);
const Color surfaceColor = Color(0xFF1E1E1E);
const Color textColor = Color(0xFFE0E0E0);
const Color accentColor = Color(0xFF4CAF50); // Green
const Color dangerColor = Color(0xFFD32F2F); // Red

// --- Main Entry Point ---
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Attempt to load Firebase config from environment or SharedPreferences
  String? configString = const String.fromEnvironment(
    'FLUTTER_WEB_CANVAS_FIREBASE_CONFIG',
    defaultValue: '',
  );

  if (configString.isEmpty) {
    final prefs = await SharedPreferences.getInstance();
    configString = prefs.getString('firebase_config');
  }

  if (configString == null || configString.isEmpty) {
    runApp(const FirebaseConfigSetupApp(initialError: 'Firebase configuration not found. Please set it up.'));
    return;
  }

  try {
    final config = jsonDecode(configString);
    if (config['apiKey'] == null || config['appId'] == null || config['messagingSenderId'] == null || config['projectId'] == null) {
      throw const FormatException("Incomplete Firebase configuration.");
    }

    final firebaseOptions = FirebaseOptions(
      apiKey: config['apiKey'],
      appId: config['appId'],
      messagingSenderId: config['messagingSenderId'],
      projectId: config['projectId'],
      storageBucket: config['storageBucket'],
    );
    
    await Firebase.initializeApp(options: firebaseOptions);

    final auth = FirebaseAuth.instance;
    await auth.signInAnonymously(); // Using anonymous sign-in for simplicity
    final userId = auth.currentUser!.uid;
    const appId = String.fromEnvironment('FLUTTER_WEB_CANVAS_APP_ID', defaultValue: 'default_jupbuddy_app');

    runApp(JupBuddyApp(
      db: FirebaseFirestore.instance,
      auth: auth,
      userId: userId,
      appId: appId,
    ));
  } catch (e) {
    runApp(FirebaseConfigSetupApp(initialError: 'Failed to initialize Firebase: $e. Please verify your configuration.'));
  }
}

class JupBuddyApp extends StatelessWidget {
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  final String userId;
  final String appId;

  const JupBuddyApp({
    super.key,
    required this.db,
    required this.auth,
    required this.userId,
    required this.appId,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => AppData(
        db: db,
        auth: auth,
        userId: userId,
        appId: appId,
      ),
      child: MaterialApp(
        title: 'JUPBuddy',
        debugShowCheckedModeBanner: false,
        theme: _buildDarkTheme(),
        initialRoute: '/login',
        routes: {
          '/login': (context) => const LoginPage(),
          '/main': (context) => const MainPage(),
        },
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    final baseTheme = ThemeData.dark();
    return baseTheme.copyWith(
      primaryColor: primaryColor,
      scaffoldBackgroundColor: darkBackgroundColor,
      colorScheme: const ColorScheme.dark(
        primary: primaryColor,
        secondary: accentColor,
        surface: surfaceColor,
        background: darkBackgroundColor,
        error: dangerColor,
        onPrimary: Colors.black,
        onSecondary: Colors.black,
        onSurface: textColor,
        onBackground: textColor,
        onError: Colors.black,
      ),
      cardTheme: CardTheme(
        color: surfaceColor,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      textTheme: baseTheme.textTheme.apply(
        bodyColor: textColor,
        displayColor: textColor,
      ).copyWith(
        titleLarge: const TextStyle(fontWeight: FontWeight.bold, color: primaryColor),
        titleMedium: const TextStyle(fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.black.withOpacity(0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.grey),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade700),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primaryColor, width: 2),
        ),
        labelStyle: const TextStyle(color: textColor),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surfaceColor,
        elevation: 0,
        titleTextStyle: TextStyle(
            color: primaryColor, fontSize: 22, fontWeight: FontWeight.bold),
        iconTheme: IconThemeData(color: primaryColor),
      ),
    );
  }
}

//==============================================================================
// 2. DATA MODELS
//==============================================================================

class UserProfile {
  String id;
  String name;
  OperationalRole operationalRole;
  List<String> allowedPlods;
  String pin;
  String? signature; // Base64 encoded image

  UserProfile({
    required this.id,
    required this.name,
    required this.operationalRole,
    required this.allowedPlods,
    required this.pin,
    this.signature,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'],
      name: json['name'],
      operationalRole: OperationalRole.values.firstWhere(
          (e) => e.toString() == json['operationalRole'],
          orElse: () => OperationalRole.Other),
      allowedPlods: List<String>.from(json['allowedPlods']),
      pin: json['pin'],
      signature: json['signature'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'operationalRole': operationalRole.toString(),
      'allowedPlods': allowedPlods,
      'pin': pin,
      'signature': signature,
    };
  }
}

class Plod {
  String id;
  String name;

  Plod({required this.id, required this.name});

  factory Plod.fromJson(Map<String, dynamic> json) =>
      Plod(id: json['id'], name: json['name']);
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class Definition {
  String id;
  String name;
  String unit;
  List<String> linkedPlods;

  Definition({
    required this.id,
    required this.name,
    required this.unit,
    required this.linkedPlods,
  });

  factory Definition.fromJson(Map<String, dynamic> json) => Definition(
        id: json['id'],
        name: json['name'],
        unit: json['unit'],
        linkedPlods: List<String>.from(json['linkedPlods']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'unit': unit,
        'linkedPlods': linkedPlods,
      };
}

class LoggedDataItem {
  String definitionId;
  String name;
  String value;
  String unit;

  LoggedDataItem({
    required this.definitionId,
    required this.name,
    required this.value,
    required this.unit,
  });

  factory LoggedDataItem.fromJson(Map<String, dynamic> json) => LoggedDataItem(
        definitionId: json['definitionId'],
        name: json['name'],
        value: json['value'],
        unit: json['unit'],
      );

  Map<String, dynamic> toJson() => {
        'definitionId': definitionId,
        'name': name,
        'value': value,
        'unit': unit,
      };
}

class LogEntry {
  String id;
  String plodId;
  String plodName;
  String userId;
  String userName;
  OperationalRole operationalRole;
  DateTime startTime;
  DateTime endTime;
  int duration; // in seconds
  ShiftType shift;
  List<LoggedDataItem> data;
  List<String> coworkers; // List of user IDs

  LogEntry({
    required this.id,
    required this.plodId,
    required this.plodName,
    required this.userId,
    required this.userName,
    required this.operationalRole,
    required this.startTime,
    required this.endTime,
    required this.duration,
    required this.shift,
    required this.data,
    required this.coworkers,
  });

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        id: json['id'],
        plodId: json['plodId'],
        plodName: json['plodName'],
        userId: json['userId'],
        userName: json['userName'],
        operationalRole: OperationalRole.values.firstWhere(
            (e) => e.toString() == json['operationalRole'],
            orElse: () => OperationalRole.Other),
        startTime: (json['startTime'] as Timestamp).toDate(),
        endTime: (json['endTime'] as Timestamp).toDate(),
        duration: json['duration'],
        shift: ShiftType.values.firstWhere(
            (e) => e.toString() == json['shift'],
            orElse: () => ShiftType.Other),
        data: (json['data'] as List)
            .map((item) => LoggedDataItem.fromJson(item))
            .toList(),
        coworkers: List<String>.from(json['coworkers']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'plodId': plodId,
        'plodName': plodName,
        'userId': userId,
        'userName': userName,
        'operationalRole': operationalRole.toString(),
        'startTime': Timestamp.fromDate(startTime),
        'endTime': Timestamp.fromDate(endTime),
        'duration': duration,
        'shift': shift.toString(),
        'data': data.map((item) => item.toJson()).toList(),
        'coworkers': coworkers,
      };
}

//==============================================================================
// 3. ENUMS
//==============================================================================

enum OperationalRole { JumboOperator, Supervisor, Trainee, Admin, Other }
enum ShiftType { DayShift, NightShift, AfternoonShift, Other }

extension OperationalRoleExtension on OperationalRole {
  String toDisplayString() {
    switch (this) {
      case OperationalRole.JumboOperator: return "Jumbo Operator";
      case OperationalRole.Supervisor: return "Supervisor";
      case OperationalRole.Trainee: return "Trainee";
      case OperationalRole.Admin: return "Admin";
      case OperationalRole.Other: return "Other";
    }
  }
}

extension ShiftTypeExtension on ShiftType {
  String toDisplayString() {
    switch (this) {
      case ShiftType.DayShift: return "Day Shift";
      case ShiftType.NightShift: return "Night Shift";
      case ShiftType.AfternoonShift: return "Afternoon Shift";
      case ShiftType.Other: return "Other";
    }
  }
}

//==============================================================================
// 4. STATE MANAGEMENT (AppData with Firebase Firestore)
//==============================================================================

class AppData extends ChangeNotifier {
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final String _appId;
  final String _userId; // This is the anonymous auth user, not the operator
  
  UserProfile? currentUser;
  List<UserProfile> users = [];
  List<Plod> plods = [];
  List<Definition> definitions = [];
  List<LogEntry> logs = [];
  bool isLoading = true;

  final List<StreamSubscription> _subscriptions = [];

  AppData({
    required FirebaseFirestore db,
    required FirebaseAuth auth,
    required String appId,
    required String userId,
  })  : _db = db,
        _auth = auth,
        _appId = appId,
        _userId = userId {
    _init();
  }

  // --- Collection References ---
  CollectionReference<Map<String, dynamic>> get _usersCollection => _db.collection('artifacts').doc(_appId).collection('users').doc(_userId).collection('user_profiles');
  CollectionReference<Map<String, dynamic>> get _plodsCollection => _db.collection('artifacts').doc(_appId).collection('users').doc(_userId).collection('plods');
  CollectionReference<Map<String, dynamic>> get _definitionsCollection => _db.collection('artifacts').doc(_appId).collection('users').doc(_userId).collection('definitions');
  CollectionReference<Map<String, dynamic>> get _logsCollection => _db.collection('artifacts').doc(_appId).collection('users').doc(_userId).collection('logs');

  void _init() {
    _listenToChanges();
  }

  void _listenToChanges() {
    isLoading = true;
    notifyListeners();

    // Clear existing subscriptions
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    // Users
    _subscriptions.add(_usersCollection.snapshots().listen((snapshot) async {
      users = snapshot.docs.map((doc) => UserProfile.fromJson(doc.data())).toList();
      if(users.isEmpty) await _addDefaultData();
      _updateLoadingState();
    }));

    // Plods
    _subscriptions.add(_plodsCollection.snapshots().listen((snapshot) {
      plods = snapshot.docs.map((doc) => Plod.fromJson(doc.data())).toList();
      _updateLoadingState();
    }));

    // Definitions
    _subscriptions.add(_definitionsCollection.snapshots().listen((snapshot) {
      definitions = snapshot.docs.map((doc) => Definition.fromJson(doc.data())).toList();
      _updateLoadingState();
    }));
    
    // Logs
    _subscriptions.add(_logsCollection.snapshots().listen((snapshot) {
      logs = snapshot.docs.map((doc) => LogEntry.fromJson(doc.data())).toList();
      _updateLoadingState();
    }));
  }

  void _updateLoadingState() {
      // Simple check, can be more robust
      if (isLoading) {
          isLoading = false;
      }
      notifyListeners();
  }

  Future<void> _addDefaultData() async {
    // Default data is only added if the user list is empty
    if (users.isNotEmpty) return;

    // Default Plods
    final defaultPlods = [
        Plod(id: 'plod_drilling', name: 'Drilling'),
        Plod(id: 'plod_bolting', name: 'Bolting'),
        Plod(id: 'plod_charging', name: 'Charging'),
    ];
    for (var plod in defaultPlods) {
        await _plodsCollection.doc(plod.id).set(plod.toJson());
    }

    // Default Definitions
    final defaultDefinitions = [
        Definition(id: 'def_holes_drilled', name: 'Holes Drilled', unit: 'count', linkedPlods: ['plod_drilling']),
        Definition(id: 'def_bolts_installed', name: 'Bolts Installed', unit: 'count', linkedPlods: ['plod_bolting']),
        Definition(id: 'def_explosives_used', name: 'Explosives Used', unit: 'kg', linkedPlods: ['plod_charging']),
        Definition(id: 'def_drill_bit_wear', name: 'Drill Bit Wear', unit: 'mm', linkedPlods: ['plod_drilling']),
    ];
    for (var def in defaultDefinitions) {
        await _definitionsCollection.doc(def.id).set(def.toJson());
    }

    // Default Users
    final defaultUsers = [
        UserProfile(id: 'admin', name: 'Admin User', operationalRole: OperationalRole.Admin, allowedPlods: ['plod_drilling', 'plod_bolting', 'plod_charging'], pin: '12345'),
        UserProfile(id: 'jumbo01', name: 'John Doe', operationalRole: OperationalRole.JumboOperator, allowedPlods: ['plod_drilling', 'plod_bolting'], pin: '00000'),
        UserProfile(id: 'super01', name: 'Jane Smith', operationalRole: OperationalRole.Supervisor, allowedPlods: ['plod_drilling', 'plod_bolting', 'plod_charging'], pin: '54321'),
    ];
    for (var user in defaultUsers) {
        await _usersCollection.doc(user.id).set(user.toJson());
    }
  }
  
  // --- User Login/Logout ---
  Future<UserProfile?> login(String userId, String pin) async {
    final user = users.firstWhereOrNull((u) => u.id == userId && u.pin == pin);
    currentUser = user;
    notifyListeners();
    return user;
  }

  void logout() {
    currentUser = null;
    notifyListeners();
  }

  // --- CRUD Operations ---
  Future<void> addUser(UserProfile user) async {
    final docRef = _usersCollection.doc();
    user.id = docRef.id;
    await docRef.set(user.toJson());
  }
  Future<void> updateUser(UserProfile user) async => await _usersCollection.doc(user.id).update(user.toJson());
  Future<void> deleteUser(String id) async => await _usersCollection.doc(id).delete();
  
  Future<void> addPlod(Plod plod) async {
    final docRef = _plodsCollection.doc();
    plod.id = docRef.id;
    await docRef.set(plod.toJson());
  }
  Future<void> updatePlod(Plod plod) async => await _plodsCollection.doc(plod.id).update(plod.toJson());
  Future<void> deletePlod(String id) async => await _plodsCollection.doc(id).delete();

  Future<void> addDefinition(Definition definition) async {
    final docRef = _definitionsCollection.doc();
    definition.id = docRef.id;
    await docRef.set(definition.toJson());
  }
  Future<void> updateDefinition(Definition definition) async => await _definitionsCollection.doc(definition.id).update(definition.toJson());
  Future<void> deleteDefinition(String id) async => await _definitionsCollection.doc(id).delete();

  Future<void> addLog(LogEntry log) async {
    final docRef = _logsCollection.doc();
    log.id = docRef.id;
    await docRef.set(log.toJson());
  }

  // --- Manual Sync ---
  Future<void> syncAllDataToCloud() async {
    final batch = _db.batch();
    for (var user in users) { batch.set(_usersCollection.doc(user.id), user.toJson()); }
    for (var plod in plods) { batch.set(_plodsCollection.doc(plod.id), plod.toJson()); }
    for (var def in definitions) { batch.set(_definitionsCollection.doc(def.id), def.toJson()); }
    for (var log in logs) { batch.set(_logsCollection.doc(log.id), log.toJson()); }
    await batch.commit();
  }

  @override
  void dispose() {
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }
}

//==============================================================================
// 5. CUSTOM ChangeNotifierProvider & FIREBASE CONFIG
//==============================================================================

// --- Custom ChangeNotifierProvider ---
class ChangeNotifierProvider<T extends ChangeNotifier> extends StatefulWidget {
  final T Function(BuildContext context) create;
  final Widget child;

  const ChangeNotifierProvider({
    super.key,
    required this.create,
    required this.child,
  });

  static T of<T extends ChangeNotifier>(BuildContext context) {
    final provider = context.dependOnInheritedWidgetOfExactType<_InheritedChangeNotifier<T>>();
    if (provider == null) {
      throw FlutterError('ChangeNotifierProvider.of() called with a context that does not contain a $T.');
    }
    return provider.notifier;
  }

  @override
  State<ChangeNotifierProvider<T>> createState() => _ChangeNotifierProviderState<T>();
}

class _ChangeNotifierProviderState<T extends ChangeNotifier> extends State<ChangeNotifierProvider<T>> {
  late T notifier;

  @override
  void initState() {
    super.initState();
    notifier = widget.create(context);
  }

  @override
  void dispose() {
    notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _InheritedChangeNotifier<T>(
      notifier: notifier,
      child: widget.child,
    );
  }
}

class _InheritedChangeNotifier<T extends ChangeNotifier> extends InheritedNotifier<T> {
  const _InheritedChangeNotifier({
    super.key,
    required T notifier,
    required super.child,
  }) : super(notifier: notifier);
}

// --- Firebase Config Setup App ---
class FirebaseConfigSetupApp extends StatelessWidget {
  final String initialError;
  const FirebaseConfigSetupApp({super.key, required this.initialError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JUPBuddy Setup',
      theme: ThemeData.dark().copyWith(
          colorScheme:
              const ColorScheme.dark(primary: primaryColor, surface: surfaceColor)),
      home: FirebaseConfigSetupPage(initialError: initialError),
    );
  }
}

// --- Firebase Config Setup Page ---
class FirebaseConfigSetupPage extends StatefulWidget {
  final String initialError;
  const FirebaseConfigSetupPage({super.key, required this.initialError});

  @override
  State<FirebaseConfigSetupPage> createState() => _FirebaseConfigSetupPageState();
}

class _FirebaseConfigSetupPageState extends State<FirebaseConfigSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _apiKeyController = TextEditingController();
  final _appIdController = TextEditingController();
  final _messagingSenderIdController = TextEditingController();
  final _projectIdController = TextEditingController();
  final _storageBucketController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(widget.initialError), backgroundColor: dangerColor));
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _appIdController.dispose();
    _messagingSenderIdController.dispose();
    _projectIdController.dispose();
    _storageBucketController.dispose();
    super.dispose();
  }

  Future<void> _saveConfiguration() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final config = {
      'apiKey': _apiKeyController.text.trim(),
      'appId': _appIdController.text.trim(),
      'messagingSenderId': _messagingSenderIdController.text.trim(),
      'projectId': _projectIdController.text.trim(),
      'storageBucket': _storageBucketController.text.trim(),
    };
    final configString = jsonEncode(config);

    try {
      final tempOptions = FirebaseOptions(
        apiKey: config['apiKey']!,
        appId: config['appId']!,
        messagingSenderId: config['messagingSenderId']!,
        projectId: config['projectId']!,
        storageBucket: config['storageBucket'],
      );
      final tempApp = await Firebase.initializeApp(
          name: 'temp_check', options: tempOptions);
      await tempApp.delete();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('firebase_config', configString);

      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Configuration saved successfully! Reloading...'),
            backgroundColor: accentColor));
      }
      
      await Future.delayed(const Duration(seconds: 2));
      html.window.location.reload();
    } catch (e) {
      if(mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('❌ Firebase Initialization Failed: $e'),
            backgroundColor: dangerColor));
      }
    } finally {
      if(mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Firebase Configuration')),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Enter your Firebase project credentials.', style: TextStyle(fontSize: 16)),
                      const SizedBox(height: 20),
                      TextFormField(controller: _apiKeyController, decoration: const InputDecoration(labelText: 'API Key'), validator: (v) => v!.isEmpty ? 'Required' : null),
                      const SizedBox(height: 12),
                      TextFormField(controller: _appIdController, decoration: const InputDecoration(labelText: 'App ID'), validator: (v) => v!.isEmpty ? 'Required' : null),
                      const SizedBox(height: 12),
                      TextFormField(controller: _messagingSenderIdController, decoration: const InputDecoration(labelText: 'Messaging Sender ID'), validator: (v) => v!.isEmpty ? 'Required' : null),
                      const SizedBox(height: 12),
                      TextFormField(controller: _projectIdController, decoration: const InputDecoration(labelText: 'Project ID'), validator: (v) => v!.isEmpty ? 'Required' : null),
                      const SizedBox(height: 12),
                      TextFormField(controller: _storageBucketController, decoration: const InputDecoration(labelText: 'Storage Bucket (Optional)')),
                      const SizedBox(height: 24),
                      _isLoading
                          ? const CircularProgressIndicator(color: primaryColor)
                          : ElevatedButton(
                              onPressed: _saveConfiguration,
                              child: const Text('Save Configuration & Reload'),
                            ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

//==============================================================================
// 6. LOGIN PAGE
//==============================================================================

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _userIdController = TextEditingController();
  final _pinController = TextEditingController();
  bool _isLoading = false;
  final _formKey = GlobalKey<FormState>();

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final userId = _userIdController.text.trim();
    final pin = _pinController.text.trim();

    final user = await appData.login(userId, pin);

    if (user != null) {
      if (user.pin == '00000') {
        // New user flow: force PIN and signature change
        final newPin = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (context) => const ForcePinChangeDialog(),
        );

        if (newPin != null) {
          final signature = await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (context) => const SignatureDialog(),
          );

          if (signature != null) {
            user.pin = newPin;
            user.signature = signature;
            await appData.updateUser(user);
            _navigateToMain();
          } else {
            appData.logout(); // Rollback login
            _showError('Signature capture was cancelled.');
          }
        } else {
          appData.logout(); // Rollback login
          _showError('PIN change was cancelled.');
        }
      } else {
        // Existing user, normal login
        _navigateToMain();
      }
    } else {
      _showError('Invalid User ID or PIN.');
    }

    if(mounted) {
      setState(() => _isLoading = false);
    }
  }
  
  void _navigateToMain() {
      Navigator.of(context).pushReplacementNamed('/main');
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: dangerColor,
    ));
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Card(
              elevation: 8,
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.shield_moon, size: 64, color: primaryColor),
                      const SizedBox(height: 16),
                      Text('JUPBuddy Login', style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: primaryColor)),
                      const SizedBox(height: 24),
                      if (appData.isLoading)
                        const Center(child: CircularProgressIndicator())
                      else ...[
                        TextFormField(
                          controller: _userIdController,
                          decoration: const InputDecoration(labelText: 'User ID', prefixIcon: Icon(Icons.person)),
                          validator: (value) => value == null || value.isEmpty ? 'Please enter your User ID' : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _pinController,
                          decoration: const InputDecoration(labelText: 'PIN', prefixIcon: Icon(Icons.lock)),
                          obscureText: true,
                          keyboardType: TextInputType.number,
                          maxLength: 5,
                          validator: (value) {
                            if (value == null || value.isEmpty) return 'Please enter your PIN';
                            if (value.length != 5) return 'PIN must be 5 digits';
                            return null;
                          },
                        ),
                        const SizedBox(height: 24),
                        _isLoading
                            ? const CircularProgressIndicator()
                            : SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _login,
                                  child: const Text('LOGIN'),
                                ),
                              ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

//==============================================================================
// 7. NEW DIALOGS (PIN CHANGE & SIGNATURE)
//==============================================================================

class ForcePinChangeDialog extends StatefulWidget {
  const ForcePinChangeDialog({super.key});

  @override
  State<ForcePinChangeDialog> createState() => _ForcePinChangeDialogState();
}

class _ForcePinChangeDialogState extends State<ForcePinChangeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _newPinController = TextEditingController();
  final _confirmPinController = TextEditingController();

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_newPinController.text);
    }
  }

  @override
  void dispose() {
    _newPinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set New PIN'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Your temporary PIN has expired. Please set a new 5-digit PIN.'),
            const SizedBox(height: 16),
            TextFormField(
              controller: _newPinController,
              decoration: const InputDecoration(labelText: 'New 5-Digit PIN'),
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 5,
              validator: (v) => v == null || v.length != 5 ? 'PIN must be 5 digits' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _confirmPinController,
              decoration: const InputDecoration(labelText: 'Confirm New PIN'),
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 5,
              validator: (v) {
                if (v != _newPinController.text) return 'PINs do not match';
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: _submit, child: const Text('Set PIN')),
      ],
    );
  }
}

class SignatureDialog extends StatefulWidget {
  const SignatureDialog({super.key});

  @override
  State<SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<SignatureDialog> {
  final SignatureController _controller = SignatureController(
    penStrokeWidth: 3,
    penColor: primaryColor,
    exportBackgroundColor: Colors.transparent,
  );

  void _saveSignature() async {
    if (_controller.isNotEmpty) {
      final Uint8List? data = await _controller.toPngBytes();
      if (data != null) {
        Navigator.of(context).pop(base64Encode(data));
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Provide Signature'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Please sign in the box below.'),
          const SizedBox(height: 16),
          Container(
            height: 200,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              color: Colors.black.withOpacity(0.3),
            ),
            child: Signature(
              controller: _controller,
              height: 200,
              backgroundColor: Colors.transparent,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => _controller.clear(), child: const Text('Clear')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: _saveSignature, child: const Text('Save Signature')),
      ],
    );
  }
}

//==============================================================================
// 8 & 9. MAIN PAGE & LIVE PLOD TRACKER
//==============================================================================

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _selectedIndex = 0;
  final PageController _pageController = PageController();

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
    _pageController.jumpToPage(index);
    Navigator.of(context).pop(); // Close the drawer
  }

  void _logout() {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    appData.logout();
    Navigator.of(context).pushReplacementNamed('/login');
  }

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final user = appData.currentUser;

    if (user == null) {
      // Should not happen, but as a safeguard
      return const Scaffold(body: Center(child: Text("Error: No user logged in.")));
    }

    final pageTitles = ['Dashboard', 'Plod Log', 'Admin Settings', 'Profile'];
    final pages = [
      const DashboardPage(),
      const PlodLogPage(),
      if(user.operationalRole == OperationalRole.Admin) const AdminSettingsPage(),
      const ProfilePage(),
    ];
    
    // Adjust page titles if admin is not present
    if (user.operationalRole != OperationalRole.Admin) {
      pageTitles.remove('Admin Settings');
    }


    return Scaffold(
      appBar: AppBar(
        title: Text('JUPBuddy - ${pageTitles[_selectedIndex]}'),
      ),
      drawer: Drawer(
        backgroundColor: darkBackgroundColor,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: const BoxDecoration(color: surfaceColor),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.person_pin_circle, size: 48, color: primaryColor),
                  const SizedBox(height: 8),
                  Text(user.name, style: Theme.of(context).textTheme.titleLarge),
                  Text(user.operationalRole.toDisplayString(), style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard),
              title: const Text('Dashboard'),
              onTap: () => _onItemTapped(0),
              selected: _selectedIndex == 0,
            ),
            ListTile(
              leading: const Icon(Icons.list_alt),
              title: const Text('Plod Log'),
              onTap: () => _onItemTapped(1),
              selected: _selectedIndex == 1,
            ),
            if (user.operationalRole == OperationalRole.Admin)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings),
                title: const Text('Admin Settings'),
                onTap: () => _onItemTapped(2),
                selected: _selectedIndex == 2,
              ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Profile'),
              onTap: () => _onItemTapped(user.operationalRole == OperationalRole.Admin ? 3 : 2),
              selected: _selectedIndex == (user.operationalRole == OperationalRole.Admin ? 3 : 2),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout, color: dangerColor),
              title: const Text('Logout', style: TextStyle(color: dangerColor)),
              onTap: _logout,
            ),
          ],
        ),
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          // This allows swiping, but the prompt doesn't specify it.
          // Keeping it simple and driven by drawer taps.
        },
        physics: const NeverScrollableScrollPhysics(), // Disable swiping
        children: pages,
      ),
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Live Plod Tracker', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: primaryColor)),
            SizedBox(height: 8),
            Card(child: LivePlodTracker()),
            // Other dashboard widgets can go here
          ],
        ),
      ),
    );
  }
}

class LivePlodTracker extends StatefulWidget {
  const LivePlodTracker({super.key});

  @override
  State<LivePlodTracker> createState() => _LivePlodTrackerState();
}

class _LivePlodTrackerState extends State<LivePlodTracker> {
  String? _selectedPlodId;
  Plod? get _selectedPlod => _selectedPlodId == null
      ? null
      : ChangeNotifierProvider.of<AppData>(context)
          .plods
          .firstWhereOrNull((p) => p.id == _selectedPlodId);

  bool _isTracking = false;
  Timer? _timer;
  int _elapsedSeconds = 0;
  DateTime? _startTime;
  ShiftType _selectedShift = ShiftType.DayShift;
  
  // Data collected during the plod
  List<LoggedDataItem> _loggedDataItems = [];
  List<String> _coworkerIds = [];
  
  bool _isLogging = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTracking() {
    setState(() {
      _isTracking = true;
      _startTime = DateTime.now();
      _elapsedSeconds = 0;
      _loggedDataItems.clear();
      _coworkerIds.clear();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() => _elapsedSeconds++);
      });
    });
  }

  Future<void> _stopAndLog() async {
    setState(() => _isLogging = true);
    _timer?.cancel();
    
    final endTime = _startTime!.add(Duration(seconds: _elapsedSeconds));

    final adjustedTimes = await showDialog<Map<String, DateTime>>(
        context: context,
        builder: (context) => TimeAdjustmentDialog(
            initialStartTime: _startTime!,
            initialEndTime: endTime,
        )
    );

    if (adjustedTimes != null) {
        final appData = ChangeNotifierProvider.of<AppData>(context);
        final user = appData.currentUser!;
        final plod = _selectedPlod!;
        
        final newLog = LogEntry(
            id: '', // Firestore will generate
            plodId: plod.id,
            plodName: plod.name,
            userId: user.id,
            userName: user.name,
            operationalRole: user.operationalRole,
            startTime: adjustedTimes['start']!,
            endTime: adjustedTimes['end']!,
            duration: adjustedTimes['end']!.difference(adjustedTimes['start']!).inSeconds,
            shift: _selectedShift,
            data: _loggedDataItems,
            coworkers: _coworkerIds,
        );

        try {
            await appData.addLog(newLog);
            if(mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('✅ Plod logged successfully!'),
                    backgroundColor: accentColor,
                ));
            }
        } catch (e) {
            if(mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('❌ Failed to log plod: $e'),
                    backgroundColor: dangerColor,
                ));
            }
        }
    }

    _resetTracker();
  }

  void _resetTracker() {
    setState(() {
      _isTracking = false;
      _isLogging = false;
      _timer?.cancel();
      _elapsedSeconds = 0;
      _selectedPlodId = null;
      _startTime = null;
      _loggedDataItems = [];
      _coworkerIds = [];
    });
  }

  String _formatDuration(int totalSeconds) {
    final duration = Duration(seconds: totalSeconds);
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$hours:$minutes:$seconds";
  }

  void _showAddDataDialog() async {
    if (_selectedPlod == null) return;
    
    final List<LoggedDataItem>? result = await showDialog(context: context, builder: (context) => 
        AddDataDialog(
            plodId: _selectedPlod!.id, 
            existingData: _loggedDataItems,
        )
    );
    
    if (result != null) {
        setState(() {
            _loggedDataItems = result;
        });
    }
  }

  void _showAddCoworkersDialog() async {
    final List<String>? result = await showDialog(context: context, builder: (context) =>
        AddCoworkersDialog(
            selectedCoworkerIds: _coworkerIds,
        )
    );

    if (result != null) {
        setState(() {
            _coworkerIds = result;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final user = appData.currentUser!;
    final allowedPlods = appData.plods.where((p) => user.allowedPlods.contains(p.id)).toList();

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: _isTracking ? _buildActiveView() : _buildSetupView(allowedPlods),
    );
  }

  Widget _buildSetupView(List<Plod> allowedPlods) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          value: _selectedPlodId,
          decoration: const InputDecoration(labelText: 'Select Plod'),
          items: allowedPlods
              .map((plod) => DropdownMenuItem(value: plod.id, child: Text(plod.name)))
              .toList(),
          onChanged: (value) => setState(() => _selectedPlodId = value),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _selectedPlodId != null ? _startTracking : null,
          child: const Text('Start Plod'),
        ),
      ],
    );
  }

  Widget _buildActiveView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          _selectedPlod?.name ?? 'Unknown Plod',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          _formatDuration(_elapsedSeconds),
          style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
        ),
        const SizedBox(height: 24),
        DropdownButtonFormField<ShiftType>(
            value: _selectedShift,
            decoration: const InputDecoration(labelText: 'Shift'),
            items: ShiftType.values
                .map((s) => DropdownMenuItem(value: s, child: Text(s.toDisplayString())))
                .toList(),
            onChanged: (v) {
                if (v != null) setState(() => _selectedShift = v);
            },
        ),
        const SizedBox(height: 16),
        Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
                OutlinedButton.icon(
                    onPressed: _showAddDataDialog, 
                    icon: const Icon(Icons.add_chart),
                    label: Text('Data (${_loggedDataItems.length})')
                ),
                OutlinedButton.icon(
                    onPressed: _showAddCoworkersDialog, 
                    icon: const Icon(Icons.group_add),
                    label: Text('Team (${_coworkerIds.length})')
                ),
            ],
        ),
        const SizedBox(height: 24),
        _isLogging 
            ? const CircularProgressIndicator()
            : ElevatedButton.icon(
                onPressed: _stopAndLog,
                icon: const Icon(Icons.stop_circle),
                label: const Text('Stop & Log Plod'),
                style: ElevatedButton.styleFrom(backgroundColor: dangerColor, foregroundColor: Colors.white),
              ),
      ],
    );
  }
}

// Dialogs for Plod Tracking
class TimeAdjustmentDialog extends StatefulWidget {
  final DateTime initialStartTime;
  final DateTime initialEndTime;
  
  const TimeAdjustmentDialog({super.key, required this.initialStartTime, required this.initialEndTime});

  @override
  State<TimeAdjustmentDialog> createState() => _TimeAdjustmentDialogState();
}

class _TimeAdjustmentDialogState extends State<TimeAdjustmentDialog> {
  late DateTime _startTime;
  late DateTime _endTime;
  
  @override
  void initState() {
    super.initState();
    _startTime = widget.initialStartTime;
    _endTime = widget.initialEndTime;
  }
  
  Future<void> _pickStartTime() async {
    final date = await showDatePicker(context: context, initialDate: _startTime, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 1)));
    if (date == null) return;
    
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_startTime));
    if (time == null) return;

    setState(() {
      _startTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }
  
  Future<void> _pickEndTime() async {
    final date = await showDatePicker(context: context, initialDate: _endTime, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 1)));
    if (date == null) return;
    
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_endTime));
    if (time == null) return;

    setState(() {
      _endTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }
  
  void _confirm() {
    if (_endTime.isBefore(_startTime)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('End time cannot be before start time.'), backgroundColor: dangerColor,));
        return;
    }
    Navigator.of(context).pop({'start': _startTime, 'end': _endTime});
  }

  String _formatDateTime(DateTime dt) {
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }
  
  String _calculateDuration() {
    final duration = _endTime.difference(_startTime);
    return "${duration.inHours}h ${duration.inMinutes.remainder(60)}m";
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirm/Adjust Times'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            ListTile(
                title: const Text('Start Time'),
                subtitle: Text(_formatDateTime(_startTime)),
                trailing: const Icon(Icons.edit),
                onTap: _pickStartTime,
            ),
            ListTile(
                title: const Text('End Time'),
                subtitle: Text(_formatDateTime(_endTime)),
                trailing: const Icon(Icons.edit),
                onTap: _pickEndTime,
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                    const Text('Calculated Duration:', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(_calculateDuration(), style: const TextStyle(fontWeight: FontWeight.bold, color: primaryColor)),
                ],
              ),
            )
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: _confirm, child: const Text('Confirm & Log')),
      ],
    );
  }
}

class AddDataDialog extends StatefulWidget {
    final String plodId;
    final List<LoggedDataItem> existingData;

  const AddDataDialog({super.key, required this.plodId, required this.existingData});

  @override
  State<AddDataDialog> createState() => _AddDataDialogState();
}

class _AddDataDialogState extends State<AddDataDialog> {
    late Map<String, TextEditingController> _controllers;
    
    @override
    void initState() {
        super.initState();
        _controllers = {};
        for (var item in widget.existingData) {
            _controllers[item.definitionId] = TextEditingController(text: item.value);
        }
    }

    @override
    void dispose() {
        for(var controller in _controllers.values) {
            controller.dispose();
        }
        super.dispose();
    }
    
    void _save() {
        final appData = ChangeNotifierProvider.of<AppData>(context);
        final relevantDefinitions = appData.definitions.where((d) => d.linkedPlods.contains(widget.plodId)).toList();
        final List<LoggedDataItem> result = [];

        for (var def in relevantDefinitions) {
            final value = _controllers[def.id]?.text.trim();
            if (value != null && value.isNotEmpty) {
                result.add(LoggedDataItem(
                    definitionId: def.id, 
                    name: def.name,
                    value: value, 
                    unit: def.unit
                ));
            }
        }
        Navigator.of(context).pop(result);
    }
    
    @override
    Widget build(BuildContext context) {
        final appData = ChangeNotifierProvider.of<AppData>(context);
        final relevantDefinitions = appData.definitions.where((d) => d.linkedPlods.contains(widget.plodId)).toList();

        if (relevantDefinitions.isEmpty) {
            return AlertDialog(
                title: const Text('Add Data'),
                content: const Text('No data definitions are linked to this plod.'),
                actions: [
                    TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))
                ],
            );
        }

        return AlertDialog(
            title: const Text('Add Data'),
            content: SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: relevantDefinitions.map((def) {
                    _controllers.putIfAbsent(def.id, () => TextEditingController());
                    
                    final existingItem = widget.existingData.firstWhereOrNull((item) => item.definitionId == def.id);
                    if (existingItem != null) {
                      _controllers[def.id]!.text = existingItem.value;
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: TextFormField(
                        controller: _controllers[def.id],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                            labelText: def.name,
                            suffixText: def.unit,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
            actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                ElevatedButton(onPressed: _save, child: const Text('Save Data')),
            ],
        );
    }
}

class AddCoworkersDialog extends StatefulWidget {
  final List<String> selectedCoworkerIds;
  const AddCoworkersDialog({super.key, required this.selectedCoworkerIds});

  @override
  State<AddCoworkersDialog> createState() => _AddCoworkersDialogState();
}

class _AddCoworkersDialogState extends State<AddCoworkersDialog> {
    late Set<String> _selectedIds;
    
    @override
    void initState() {
        super.initState();
        _selectedIds = widget.selectedCoworkerIds.toSet();
    }
    
    void _onChanged(bool? value, String userId) {
        setState(() {
            if(value == true) {
                _selectedIds.add(userId);
            } else {
                _selectedIds.remove(userId);
            }
        });
    }
    
    @override
    Widget build(BuildContext context) {
        final appData = ChangeNotifierProvider.of<AppData>(context);
        final currentUser = appData.currentUser!;
        final otherUsers = appData.users.where((u) => u.id != currentUser.id).toList();

        return AlertDialog(
            title: const Text('Add Co-workers'),
            content: SizedBox(
                width: 300,
                child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: otherUsers.length,
                    itemBuilder: (context, index) {
                        final user = otherUsers[index];
                        return CheckboxListTile(
                            title: Text(user.name),
                            subtitle: Text(user.operationalRole.toDisplayString()),
                            value: _selectedIds.contains(user.id), 
                            onChanged: (val) => _onChanged(val, user.id),
                        );
                    },
                ),
            ),
            actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                ElevatedButton(onPressed: () => Navigator.of(context).pop(_selectedIds.toList()), child: const Text('Confirm')),
            ],
        );
    }
}

//==============================================================================
// 10. PLOD LOG PAGE
//==============================================================================

enum SortLogBy { date, plodName, userName, duration }

class PlodLogPage extends StatefulWidget {
  const PlodLogPage({super.key});

  @override
  State<PlodLogPage> createState() => _PlodLogPageState();
}

class _PlodLogPageState extends State<PlodLogPage> {
  String _searchQuery = '';
  SortLogBy _sortBy = SortLogBy.date;
  bool _sortAscending = false;
  
  // Filters
  DateTimeRange? _dateFilter;
  String? _plodFilterId;
  String? _userFilterId;

  List<LogEntry> _getFilteredAndSortedLogs(AppData appData) {
    List<LogEntry> logs = List.from(appData.logs);

    // Apply Filters
    if (_dateFilter != null) {
      logs = logs.where((log) => log.startTime.isAfter(_dateFilter!.start) && log.startTime.isBefore(_dateFilter!.end)).toList();
    }
    if (_plodFilterId != null) {
      logs = logs.where((log) => log.plodId == _plodFilterId).toList();
    }
    if (_userFilterId != null) {
      logs = logs.where((log) => log.userId == _userFilterId).toList();
    }

    // Apply Search
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      logs = logs.where((log) {
        return log.plodName.toLowerCase().contains(query) ||
            log.userName.toLowerCase().contains(query) ||
            log.operationalRole.toDisplayString().toLowerCase().contains(query) ||
            log.data.any((d) => d.name.toLowerCase().contains(query) || d.value.toLowerCase().contains(query));
      }).toList();
    }

    // Apply Sort
    logs.sort((a, b) {
      int comparison;
      switch (_sortBy) {
        case SortLogBy.date:
          comparison = a.startTime.compareTo(b.startTime);
          break;
        case SortLogBy.plodName:
          comparison = a.plodName.compareTo(b.plodName);
          break;
        case SortLogBy.userName:
          comparison = a.userName.compareTo(b.userName);
          break;
        case SortLogBy.duration:
          comparison = a.duration.compareTo(b.duration);
          break;
      }
      return _sortAscending ? comparison : -comparison;
    });

    return logs;
  }
  
  Future<void> _exportToCSV(List<LogEntry> logs) async {
      final List<List<dynamic>> rows = [];
      // Header
      rows.add([
        'ID', 'Plod Name', 'User Name', 'Role', 'Start Time', 'End Time',
        'Duration (s)', 'Shift', 'Co-workers (IDs)', 'Logged Data (Name:Value;...)'
      ]);
      // Data
      for (final log in logs) {
        rows.add([
          log.id,
          log.plodName,
          log.userName,
          log.operationalRole.toDisplayString(),
          DateFormat('yyyy-MM-dd HH:mm').format(log.startTime),
          DateFormat('yyyy-MM-dd HH:mm').format(log.endTime),
          log.duration,
          log.shift.toDisplayString(),
          log.coworkers.join(';'),
          log.data.map((d) => '${d.name}:${d.value}').join(';'),
        ]);
      }

      String csv = const ListToCsvConverter().convert(rows);
      final bytes = utf8.encode(csv);
      
      try {
        await FileSaver.instance.saveFile(
            name: 'jupbuddy_logs_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv',
            bytes: bytes,
            ext: 'csv',
            mimeType: MimeType.csv,
        );
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ CSV Exported!'), backgroundColor: accentColor));
      } catch (e) {
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ CSV Export Failed: $e'), backgroundColor: dangerColor));
      }
  }

  Future<void> _generatePdfReport(List<LogEntry> logs) async {
    final pdf = pw.Document();
    final appData = ChangeNotifierProvider.of<AppData>(context);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(
            level: 0,
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('JUPBuddy - Plod Log Report', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 20)),
                pw.Text(DateFormat('yyyy-MM-dd').format(DateTime.now())),
              ],
            ),
          ),
          pw.Divider(),
          pw.SizedBox(height: 10),
          for (final log in logs)
            pw.Container(
              padding: const pw.EdgeInsets.all(10),
              margin: const pw.EdgeInsets.only(bottom: 10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey),
                borderRadius: pw.BorderRadius.circular(5),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('${log.plodName} by ${log.userName}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14)),
                  pw.SizedBox(height: 5),
                  pw.Text('Time: ${DateFormat('yyyy-MM-dd HH:mm').format(log.startTime)} to ${DateFormat('HH:mm').format(log.endTime)}'),
                  pw.Text('Duration: ${Duration(seconds: log.duration).inMinutes} minutes'),
                  pw.Text('Shift: ${log.shift.toDisplayString()}'),
                  if(log.coworkers.isNotEmpty)
                    pw.Text('Co-workers: ${log.coworkers.map((id) => appData.users.firstWhereOrNull((u) => u.id == id)?.name ?? id).join(', ')}'),
                  if(log.data.isNotEmpty) ...[
                      pw.SizedBox(height: 5),
                      pw.Text('Logged Data:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      pw.Table.fromTextArray(
                          context: context,
                          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          data: <List<String>>[
                              <String>['Item', 'Value', 'Unit'],
                              ...log.data.map((d) => [d.name, d.value, d.unit])
                          ]
                      )
                  ]
                ]
              )
            ),
        ],
      ),
    );

    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save());
  }
  
  void _printHtmlReport(List<LogEntry> logs) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final buffer = StringBuffer();
    buffer.writeln('<html><head><title>JUPBuddy Report</title>');
    buffer.writeln('<style> body { font-family: sans-serif; margin: 2em; } table { border-collapse: collapse; width: 100%; } th, td { border: 1px solid #ddd; padding: 8px; text-align: left; } tr:nth-child(even) { background-color: #f2f2f2; } </style>');
    buffer.writeln('</head><body>');
    buffer.writeln('<h1>JUPBuddy - Plod Log Report</h1>');
    buffer.writeln('<p>Generated on: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}</p>');
    buffer.writeln('<table>');
    buffer.writeln('<tr><th>Plod</th><th>User</th><th>Start Time</th><th>Duration</th><th>Data</th><th>Co-workers</th></tr>');

    for (final log in logs) {
        buffer.writeln('<tr>');
        buffer.writeln('<td>${log.plodName}</td>');
        buffer.writeln('<td>${log.userName}</td>');
        buffer.writeln('<td>${DateFormat('yyyy-MM-dd HH:mm').format(log.startTime)}</td>');
        buffer.writeln('<td>${Duration(seconds: log.duration).inMinutes} min</td>');
        buffer.writeln('<td>${log.data.map((d) => '${d.name}: ${d.value} ${d.unit}').join('<br>')}</td>');
        buffer.writeln('<td>${log.coworkers.map((id) => appData.users.firstWhereOrNull((u) => u.id == id)?.name ?? id).join(', ')}</td>');
        buffer.writeln('</tr>');
    }

    buffer.writeln('</table></body></html>');
    
    final blob = html.Blob([buffer.toString()], 'text/html');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final filteredLogs = _getFilteredAndSortedLogs(appData);

    return Column(
      children: [
        _buildToolbar(filteredLogs),
        Expanded(
          child: filteredLogs.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  itemCount: filteredLogs.length,
                  itemBuilder: (context, index) {
                    final log = filteredLogs[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: ListTile(
                        leading: CircleAvatar(backgroundColor: primaryColor, child: Text(log.plodName.substring(0,1), style: const TextStyle(color: Colors.black))),
                        title: Text('${log.plodName} - ${log.userName}'),
                        subtitle: Text(
                            '${DateFormat('yyyy-MM-dd HH:mm').format(log.startTime)} | ${log.shift.toDisplayString()}'),
                        trailing: Text('${Duration(seconds: log.duration).inMinutes} min', style: const TextStyle(color: primaryColor, fontWeight: FontWeight.bold)),
                        onTap: () => showDialog(
                            context: context,
                            builder: (_) => PlodLogDetailDialog(log: log),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildToolbar(List<LogEntry> logs) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: const InputDecoration(
                      labelText: 'Search Logs',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.filter_list),
                  tooltip: 'Filter',
                  onPressed: () async {
                    final filters = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (context) => FilterLogDialog(
                        initialDateRange: _dateFilter,
                        initialPlodId: _plodFilterId,
                        initialUserId: _userFilterId,
                      ),
                    );
                    if (filters != null) {
                      setState(() {
                        _dateFilter = filters['date'];
                        _plodFilterId = filters['plod'];
                        _userFilterId = filters['user'];
                      });
                    }
                  },
                ),
                PopupMenuButton<SortLogBy>(
                  icon: const Icon(Icons.sort),
                  tooltip: 'Sort By',
                  onSelected: (sort) {
                    setState(() {
                      if (_sortBy == sort) {
                        _sortAscending = !_sortAscending;
                      } else {
                        _sortBy = sort;
                        _sortAscending = true;
                      }
                    });
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: SortLogBy.date, child: Text('Sort by Date')),
                    const PopupMenuItem(value: SortLogBy.plodName, child: Text('Sort by Plod Name')),
                    const PopupMenuItem(value: SortLogBy.userName, child: Text('Sort by User Name')),
                    const PopupMenuItem(value: SortLogBy.duration, child: Text('Sort by Duration')),
                  ],
                ),
                PopupMenuButton<String>(
                    icon: const Icon(Icons.ios_share),
                    tooltip: 'Export',
                    onSelected: (value) {
                        if (value == 'CSV') _exportToCSV(logs);
                        if (value == 'PDF') _generatePdfReport(logs);
                        if (value == 'HTML') _printHtmlReport(logs);
                    },
                    itemBuilder: (context) => [
                        const PopupMenuItem(value: 'CSV', child: ListTile(leading: Icon(Icons.description), title: Text('Export to CSV'))),
                        const PopupMenuItem(value: 'PDF', child: ListTile(leading: Icon(Icons.picture_as_pdf), title: Text('Generate PDF'))),
                        const PopupMenuItem(value: 'HTML', child: ListTile(leading: Icon(Icons.print), title: Text('Print Report'))),
                    ],
                )
              ],
            ),
            if (_dateFilter != null || _plodFilterId != null || _userFilterId != null)
                _buildFilterChips(),
        ],
      ),
    );
  }
  
  Widget _buildFilterChips() {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, left: 8.0),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
            if (_dateFilter != null) Chip(
                label: Text('${DateFormat.yMd().format(_dateFilter!.start)} - ${DateFormat.yMd().format(_dateFilter!.end)}'),
                onDeleted: () => setState(() => _dateFilter = null),
            ),
            if (_plodFilterId != null) Chip(
                label: Text('Plod: ${appData.plods.firstWhereOrNull((p) => p.id == _plodFilterId)?.name ?? '...'}'),
                onDeleted: () => setState(() => _plodFilterId = null),
            ),
            if (_userFilterId != null) Chip(
                label: Text('User: ${appData.users.firstWhereOrNull((u) => u.id == _userFilterId)?.name ?? '...'}'),
                onDeleted: () => setState(() => _userFilterId = null),
            ),
            ActionChip(
                label: const Text('Clear All'),
                avatar: const Icon(Icons.clear_all, size: 16),
                onPressed: () => setState(() {
                    _dateFilter = null;
                    _plodFilterId = null;
                    _userFilterId = null;
                }),
            )
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inbox_outlined, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'No Logs Found',
            style: TextStyle(fontSize: 22, color: Colors.grey),
          ),
          SizedBox(height: 8),
          Text(
            'Try adjusting your search or filter criteria.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class PlodLogDetailDialog extends StatelessWidget {
  final LogEntry log;
  const PlodLogDetailDialog({super.key, required this.log});

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final coworkerNames = log.coworkers
        .map((id) => appData.users.firstWhereOrNull((u) => u.id == id)?.name ?? id)
        .join(', ');

    return AlertDialog(
      title: Text('Log Detail: ${log.plodName}'),
      content: SingleChildScrollView(
        child: ListBody(
          children: [
            _buildDetailRow('User:', '${log.userName} (${log.operationalRole.toDisplayString()})'),
            _buildDetailRow('Time:', '${DateFormat('yyyy-MM-dd HH:mm').format(log.startTime)} - ${DateFormat('HH:mm').format(log.endTime)}'),
            _buildDetailRow('Duration:', '${Duration(seconds: log.duration).inMinutes} minutes'),
            _buildDetailRow('Shift:', log.shift.toDisplayString()),
            if (coworkerNames.isNotEmpty) _buildDetailRow('Co-workers:', coworkerNames),
            const Divider(height: 20),
            const Text('Logged Data', style: TextStyle(fontWeight: FontWeight.bold)),
            if (log.data.isEmpty) const Text('No data items logged.') else ...log.data.map((d) => _buildDetailRow('${d.name}:', '${d.value} ${d.unit}')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class FilterLogDialog extends StatefulWidget {
    final DateTimeRange? initialDateRange;
    final String? initialPlodId;
    final String? initialUserId;
    
  const FilterLogDialog({super.key, this.initialDateRange, this.initialPlodId, this.initialUserId});

  @override
  State<FilterLogDialog> createState() => _FilterLogDialogState();
}

class _FilterLogDialogState extends State<FilterLogDialog> {
    DateTimeRange? _selectedDateRange;
    String? _selectedPlodId;
    String? _selectedUserId;

    @override
    void initState() {
        super.initState();
        _selectedDateRange = widget.initialDateRange;
        _selectedPlodId = widget.initialPlodId;
        _selectedUserId = widget.initialUserId;
    }

    void _applyFilters() {
        Navigator.of(context).pop({
            'date': _selectedDateRange,
            'plod': _selectedPlodId,
            'user': _selectedUserId,
        });
    }

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    return AlertDialog(
        title: const Text('Filter Logs'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
                ListTile(
                    title: const Text('Date Range'),
                    subtitle: Text(_selectedDateRange == null 
                        ? 'Any' 
                        : '${DateFormat.yMd().format(_selectedDateRange!.start)} - ${DateFormat.yMd().format(_selectedDateRange!.end)}'),
                    onTap: () async {
                        final range = await showDateRangePicker(
                            context: context, 
                            firstDate: DateTime(2020), 
                            lastDate: DateTime.now().add(const Duration(days: 1)),
                            initialDateRange: _selectedDateRange,
                        );
                        if(range != null) setState(() => _selectedDateRange = range);
                    },
                ),
                DropdownButtonFormField<String>(
                    value: _selectedPlodId,
                    decoration: const InputDecoration(labelText: 'Filter by Plod'),
                    items: [
                        const DropdownMenuItem<String>(value: null, child: Text('All Plods')),
                        ...appData.plods.map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                    ],
                    onChanged: (val) => setState(() => _selectedPlodId = val),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                    value: _selectedUserId,
                    decoration: const InputDecoration(labelText: 'Filter by User'),
                    items: [
                        const DropdownMenuItem<String>(value: null, child: Text('All Users')),
                        ...appData.users.map((u) => DropdownMenuItem(value: u.id, child: Text(u.name)))
                    ],
                    onChanged: (val) => setState(() => _selectedUserId = val),
                ),
            ],
        ),
        actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            ElevatedButton(onPressed: _applyFilters, child: const Text('Apply Filters')),
        ],
    );
  }
}


//==============================================================================
// 11. PROFILE PAGE
//==============================================================================

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
    final _currentPinController = TextEditingController();
    final _newPinController = TextEditingController();
    final _confirmPinController = TextEditingController();
    final _pinFormKey = GlobalKey<FormState>();
    bool _isChangingPin = false;
    bool _isSyncing = false;

    Future<void> _changePin() async {
        if(!_pinFormKey.currentState!.validate()) return;
        
        setState(() => _isChangingPin = true);
        final appData = ChangeNotifierProvider.of<AppData>(context);
        final user = appData.currentUser!;
        
        if (user.pin != _currentPinController.text) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Current PIN is incorrect.'), backgroundColor: dangerColor));
            setState(() => _isChangingPin = false);
            return;
        }

        user.pin = _newPinController.text;
        try {
            await appData.updateUser(user);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ PIN changed successfully!'), backgroundColor: accentColor));
            _currentPinController.clear();
            _newPinController.clear();
            _confirmPinController.clear();
        } catch(e) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ Failed to change PIN: $e'), backgroundColor: dangerColor));
        } finally {
            if(mounted) setState(() => _isChangingPin = false);
        }
    }

    Future<void> _syncData() async {
        setState(() => _isSyncing = true);
        final appData = ChangeNotifierProvider.of<AppData>(context);
        try {
            await appData.syncAllDataToCloud();
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ All data synced to cloud!'), backgroundColor: accentColor));
        } catch(e) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ Sync failed: $e'), backgroundColor: dangerColor));
        } finally {
            if(mounted) setState(() => _isSyncing = false);
        }
    }
    
    @override
    void dispose() {
        _currentPinController.dispose();
        _newPinController.dispose();
        _confirmPinController.dispose();
        super.dispose();
    }

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final user = appData.currentUser!;
    final assignedPlods = appData.plods.where((p) => user.allowedPlods.contains(p.id)).map((p) => p.name).join(', ');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(user.name, style: Theme.of(context).textTheme.headlineMedium),
                            const SizedBox(height: 8),
                            Text('ID: ${user.id}', style: const TextStyle(color: Colors.grey)),
                            Text('Role: ${user.operationalRole.toDisplayString()}', style: const TextStyle(color: Colors.grey)),
                            const SizedBox(height: 16),
                            const Text('Assigned Plods:', style: TextStyle(fontWeight: FontWeight.bold)),
                            Text(assignedPlods.isNotEmpty ? assignedPlods : 'None'),
                          ],
                        ),
                      ),
                      if (user.signature != null) ...[
                        const SizedBox(width: 16),
                        Column(
                          children: [
                            const Text('Signature'),
                            const SizedBox(height: 8),
                            Container(
                                width: 150,
                                height: 75,
                                color: Colors.black.withOpacity(0.3),
                                child: Image.memory(base64Decode(user.signature!), fit: BoxFit.contain),
                            )
                          ],
                        )
                      ]
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Form(
                    key: _pinFormKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Change PIN', style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 16),
                        TextFormField(controller: _currentPinController, decoration: const InputDecoration(labelText: 'Current PIN'), obscureText: true, validator: (v) => v!.isEmpty ? 'Required' : null),
                        const SizedBox(height: 12),
                        TextFormField(controller: _newPinController, decoration: const InputDecoration(labelText: 'New PIN'), obscureText: true, maxLength: 5, validator: (v) => v!.length != 5 ? 'Must be 5 digits' : null),
                        const SizedBox(height: 12),
                        TextFormField(controller: _confirmPinController, decoration: const InputDecoration(labelText: 'Confirm New PIN'), obscureText: true, maxLength: 5, validator: (v) => v != _newPinController.text ? 'PINs do not match' : null),
                        const SizedBox(height: 16),
                        _isChangingPin ? const CircularProgressIndicator() : ElevatedButton(onPressed: _changePin, child: const Text('Update PIN')),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                             Text('Data Synchronization', style: Theme.of(context).textTheme.titleLarge),
                             const SizedBox(height: 8),
                             const Text('Manually force a sync of all local data to the cloud. This is usually not needed as data syncs in real-time.'),
                             const SizedBox(height: 16),
                             _isSyncing ? const CircularProgressIndicator() : ElevatedButton(onPressed: _syncData, child: const Text('Sync All Data to Cloud')),
                        ],
                    )
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

//==============================================================================
// 12. ADMIN SETTINGS PAGES
//==============================================================================

class AdminSettingsPage extends StatelessWidget {
  const AdminSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false, // No back button
          backgroundColor: darkBackgroundColor,
          flexibleSpace: const TabBar(
            indicatorColor: primaryColor,
            labelColor: primaryColor,
            unselectedLabelColor: Colors.grey,
            tabs: [
              Tab(icon: Icon(Icons.people), text: 'Users'),
              Tab(icon: Icon(Icons.build_circle), text: 'Plods'),
              Tab(icon: Icon(Icons.schema), text: 'Definitions'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            UserManagementPage(),
            PlodManagementPage(),
            DefinitionManagementPage(),
          ],
        ),
      ),
    );
  }
}

// --- User Management ---
class UserManagementPage extends StatefulWidget {
  const UserManagementPage({super.key});
  @override
  State<UserManagementPage> createState() => _UserManagementPageState();
}

class _UserManagementPageState extends State<UserManagementPage> {
    String _searchQuery = '';

    Future<void> _deleteUser(UserProfile user) async {
        final confirm = await _showConfirmDialog(context, 'Delete User', 'Are you sure you want to delete ${user.name}? This cannot be undone.');
        if (confirm == true) {
            final appData = ChangeNotifierProvider.of<AppData>(context);
            try {
                await appData.deleteUser(user.id);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ User deleted.'), backgroundColor: accentColor));
            } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ Error: $e'), backgroundColor: dangerColor));
            }
        }
    }

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final users = appData.users.where((u) => u.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    
    return Scaffold(
      body: Column(
        children: [
            Padding(
                padding: const EdgeInsets.all(8.0),
                child: TextField(onChanged: (v) => setState(() => _searchQuery = v), decoration: const InputDecoration(labelText: 'Search Users', prefixIcon: Icon(Icons.search))),
            ),
            Expanded(
                child: users.isEmpty
                    ? const Center(child: Text('No users found.'))
                    : ListView.builder(
                        itemCount: users.length,
                        itemBuilder: (context, index) {
                            final user = users[index];
                            return ListTile(
                                title: Text(user.name),
                                subtitle: Text('${user.id} - ${user.operationalRole.toDisplayString()}'),
                                trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                        IconButton(icon: const Icon(Icons.edit), onPressed: () => showDialog(context: context, builder: (_) => AddEditUserDialog(user: user))),
                                        IconButton(icon: const Icon(Icons.delete, color: dangerColor), onPressed: () => _deleteUser(user)),
                                    ],
                                ),
                            );
                        },
                      ),
            )
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog(context: context, builder: (_) => const AddEditUserDialog()),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class AddEditUserDialog extends StatefulWidget {
    final UserProfile? user;
    const AddEditUserDialog({super.key, this.user});
    @override
    State<AddEditUserDialog> createState() => _AddEditUserDialogState();
}

class _AddEditUserDialogState extends State<AddEditUserDialog> {
    final _formKey = GlobalKey<FormState>();
    late String _id;
    late TextEditingController _nameController;
    late OperationalRole _role;
    late List<String> _allowedPlods;
    bool _isSaving = false;

    @override
    void initState() {
        super.initState();
        final user = widget.user;
        _id = user?.id ?? '';
        _nameController = TextEditingController(text: user?.name);
        _role = user?.operationalRole ?? OperationalRole.JumboOperator;
        _allowedPlods = user?.allowedPlods ?? [];
    }
    
    @override
    void dispose() {
        _nameController.dispose();
        super.dispose();
    }

    Future<void> _save() async {
        if(!_formKey.currentState!.validate()) return;
        setState(() => _isSaving = true);
        final appData = ChangeNotifierProvider.of<AppData>(context);
        
        final userProfile = UserProfile(
            id: _id,
            name: _nameController.text,
            operationalRole: _role,
            allowedPlods: _allowedPlods,
            pin: widget.user?.pin ?? '00000', // New users get a reset PIN
        );

        try {
            if(widget.user == null) {
                await appData.addUser(userProfile);
            } else {
                await appData.updateUser(userProfile);
            }
            Navigator.of(context).pop();
        } catch(e) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ Save failed: $e'), backgroundColor: dangerColor));
        } finally {
            if(mounted) setState(() => _isSaving = false);
        }
    }

    @override
    Widget build(BuildContext context) {
        final appData = ChangeNotifierProvider.of<AppData>(context);
        return AlertDialog(
            title: Text(widget.user == null ? 'Add User' : 'Edit User'),
            content: Form(
                key: _formKey,
                child: SingleChildScrollView(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                            if (widget.user != null) Text('User ID: ${_id}', style: const TextStyle(color: Colors.grey)),
                            TextFormField(controller: _nameController, decoration: const InputDecoration(labelText: 'Name'), validator: (v) => v!.isEmpty ? 'Required' : null),
                            DropdownButtonFormField<OperationalRole>(
                                value: _role,
                                decoration: const InputDecoration(labelText: 'Role'),
                                items: OperationalRole.values.map((r) => DropdownMenuItem(value: r, child: Text(r.toDisplayString()))).toList(),
                                onChanged: (val) => setState(() => _role = val!),
                            ),
                            const SizedBox(height: 16),
                            const Text('Allowed Plods'),
                            ...appData.plods.map((plod) => CheckboxListTile(
                                title: Text(plod.name),
                                value: _allowedPlods.contains(plod.id),
                                onChanged: (val) {
                                    setState(() {
                                        if (val == true) {
                                            _allowedPlods.add(plod.id);
                                        } else {
                                            _allowedPlods.remove(plod.id);
                                        }
                                    });
                                },
                            )).toList()
                        ],
                    ),
                ),
            ),
            actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                _isSaving ? const CircularProgressIndicator() : ElevatedButton(onPressed: _save, child: const Text('Save')),
            ],
        );
    }
}


// --- Plod & Definition Management (similar structure to User Management) ---

class PlodManagementPage extends StatefulWidget {
  const PlodManagementPage({super.key});
  @override
  State<PlodManagementPage> createState() => _PlodManagementPageState();
}

class _PlodManagementPageState extends State<PlodManagementPage> {
    String _searchQuery = '';

    Future<void> _deletePlod(Plod plod) async {
        final confirm = await _showConfirmDialog(context, 'Delete Plod', 'Are you sure you want to delete ${plod.name}?');
        if (confirm == true) {
            final appData = ChangeNotifierProvider.of<AppData>(context);
            await appData.deletePlod(plod.id);
        }
    }

  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final plods = appData.plods.where((p) => p.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    
    return Scaffold(
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(8.0), child: TextField(onChanged: (v) => setState(() => _searchQuery = v), decoration: const InputDecoration(labelText: 'Search Plods', prefixIcon: Icon(Icons.search)))),
        Expanded(
            child: ListView.builder(
                itemCount: plods.length,
                itemBuilder: (context, index) {
                    final plod = plods[index];
                    return ListTile(
                        title: Text(plod.name),
                        subtitle: Text(plod.id),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(icon: const Icon(Icons.edit), onPressed: () => showDialog(context: context, builder: (_) => AddEditPlodDialog(plod: plod))),
                            IconButton(icon: const Icon(Icons.delete, color: dangerColor), onPressed: () => _deletePlod(plod)),
                        ]),
                    );
                },
            ),
        )
      ]),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog(context: context, builder: (_) => const AddEditPlodDialog()),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class AddEditPlodDialog extends StatefulWidget {
    final Plod? plod;
    const AddEditPlodDialog({super.key, this.plod});
    @override
    State<AddEditPlodDialog> createState() => _AddEditPlodDialogState();
}
class _AddEditPlodDialogState extends State<AddEditPlodDialog> {
    final _formKey = GlobalKey<FormState>();
    late String _id;
    late TextEditingController _nameController;

    @override
    void initState() {
        super.initState();
        _id = widget.plod?.id ?? '';
        _nameController = TextEditingController(text: widget.plod?.name);
    }
    
    Future<void> _save() async {
        if(!_formKey.currentState!.validate()) return;
        final appData = ChangeNotifierProvider.of<AppData>(context);
        final newPlod = Plod(id: _id, name: _nameController.text);
        if(widget.plod == null) await appData.addPlod(newPlod);
        else await appData.updatePlod(newPlod);
        Navigator.of(context).pop();
    }
    
    @override
    Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.plod == null ? 'Add Plod' : 'Edit Plod'),
        content: Form(
            key: _formKey,
            child: TextFormField(controller: _nameController, decoration: const InputDecoration(labelText: 'Plod Name'), validator: (v) => v!.isEmpty ? 'Required' : null),
        ),
        actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            ElevatedButton(onPressed: _save, child: const Text('Save')),
        ],
    );
}

class DefinitionManagementPage extends StatefulWidget {
  const DefinitionManagementPage({super.key});
  @override
  State<DefinitionManagementPage> createState() => _DefinitionManagementPageState();
}

class _DefinitionManagementPageState extends State<DefinitionManagementPage> {
    String _searchQuery = '';

    Future<void> _deleteDef(Definition def) async {
        final confirm = await _showConfirmDialog(context, 'Delete Definition', 'Are you sure you want to delete ${def.name}?');
        if (confirm == true) {
            final appData = ChangeNotifierProvider.of<AppData>(context);
            await appData.deleteDefinition(def.id);
        }
    }
    
  @override
  Widget build(BuildContext context) {
    final appData = ChangeNotifierProvider.of<AppData>(context);
    final definitions = appData.definitions.where((d) => d.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    
    return Scaffold(
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(8.0), child: TextField(onChanged: (v) => setState(() => _searchQuery = v), decoration: const InputDecoration(labelText: 'Search Definitions', prefixIcon: Icon(Icons.search)))),
        Expanded(
            child: ListView.builder(
                itemCount: definitions.length,
                itemBuilder: (context, index) {
                    final def = definitions[index];
                    return ListTile(
                        title: Text('${def.name} (${def.unit})'),
                        subtitle: Text('Linked Plods: ${def.linkedPlods.length}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(icon: const Icon(Icons.edit), onPressed: () => showDialog(context: context, builder: (_) => AddEditDefinitionDialog(definition: def))),
                            IconButton(icon: const Icon(Icons.delete, color: dangerColor), onPressed: () => _deleteDef(def)),
                        ]),
                    );
                },
            ),
        )
      ]),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog(context: context, builder: (_) => const AddEditDefinitionDialog()),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class AddEditDefinitionDialog extends StatefulWidget {
    final Definition? definition;
    const AddEditDefinitionDialog({super.key, this.definition});
    @override
    State<AddEditDefinitionDialog> createState() => _AddEditDefinitionDialogState();
}

class _AddEditDefinitionDialogState extends State<AddEditDefinitionDialog> {
    final _formKey = GlobalKey<FormState>();
    late String _id;
    late TextEditingController _nameController;
    late TextEditingController _unitController;
    late List<String> _linkedPlods;

    @override
    void initState() {
        super.initState();
        final def = widget.definition;
        _id = def?.id ?? '';
        _nameController = TextEditingController(text: def?.name);
        _unitController = TextEditingController(text: def?.unit);
        _linkedPlods = def?.linkedPlods ?? [];
    }
    
    Future<void> _save() async {
        if(!_formKey.currentState!.validate()) return;
        final appData = ChangeNotifierProvider.of<AppData>(context);
        final newDef = Definition(id: _id, name: _nameController.text, unit: _unitController.text, linkedPlods: _linkedPlods);
        if(widget.definition == null) await appData.addDefinition(newDef);
        else await appData.updateDefinition(newDef);
        Navigator.of(context).pop();
    }

    @override
    Widget build(BuildContext context) {
        final appData = ChangeNotifierProvider.of<AppData>(context);
        return AlertDialog(
            title: Text(widget.definition == null ? 'Add Definition' : 'Edit Definition'),
            content: Form(
                key: _formKey,
                child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                        TextFormField(controller: _nameController, decoration: const InputDecoration(labelText: 'Name'), validator: (v) => v!.isEmpty ? 'Required' : null),
                        TextFormField(controller: _unitController, decoration: const InputDecoration(labelText: 'Unit'), validator: (v) => v!.isEmpty ? 'Required' : null),
                        const SizedBox(height: 16),
                        const Text('Linked Plods'),
                        ...appData.plods.map((plod) => CheckboxListTile(
                            title: Text(plod.name),
                            value: _linkedPlods.contains(plod.id),
                            onChanged: (val) {
                                setState(() {
                                    if(val == true) _linkedPlods.add(plod.id);
                                    else _linkedPlods.remove(plod.id);
                                });
                            },
                        )).toList(),
                    ]),
                ),
            ),
            actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                ElevatedButton(onPressed: _save, child: const Text('Save')),
            ],
        );
    }
}


//==============================================================================
// 13. GENERAL UI/UX & UTILITIES
//==============================================================================

/// A generic confirmation dialog for delete actions.
Future<bool?> _showConfirmDialog(BuildContext context, String title, String content) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: dangerColor),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
}
