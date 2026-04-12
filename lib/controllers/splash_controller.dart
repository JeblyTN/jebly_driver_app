import 'dart:async';
import 'dart:developer';
import 'package:driver/app/auth_screen/login_screen.dart';
import 'package:driver/app/dash_board_screen/dash_board_screen.dart';
import 'package:driver/app/maintenance_mode_screen/maintenance_mode_screen.dart';
import 'package:driver/app/on_boarding_screen.dart';
import 'package:driver/constant/constant.dart';
import 'package:driver/controllers/dash_board_controller.dart';
import 'package:driver/models/user_model.dart';
import 'package:driver/utils/fire_store_utils.dart';
import 'package:driver/utils/notification_service.dart';
import 'package:driver/utils/preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:get/get.dart';

class SplashController extends GetxController {
  @override
  void onInit() {
    Timer(const Duration(seconds: 3), () => redirectScreen());
    super.onInit();
  }

  Future<void> redirectScreen() async {
    if (await FireStoreUtils.isMaintenanceMode() == true) {
      Get.offAll(() => MaintenanceModeScreen());
      return;
    } else {
      if (Preferences.getBoolean(Preferences.isClickOnNotification) != true) {
        if (Preferences.getBoolean(Preferences.isFinishOnBoardingKey) == false) {
          Get.offAll(const OnBoardingScreen());
        } else {
          bool isLogin = await FireStoreUtils.isLogin();
          if (isLogin == true) {
            await FireStoreUtils.getUserProfile(FireStoreUtils.getCurrentUid()).then((value) async {
              if (value != null) {
                UserModel userModel = value;
                Constant.userModel = userModel;
                log(userModel.toJson().toString());
                if (userModel.role == Constant.userRoleDriver) {
                  if (userModel.active == true) {
                    userModel.fcmToken = await NotificationService.getToken();
                    await FireStoreUtils.updateUser(userModel);
                    RemoteMessage? initialMessage = await FirebaseMessaging.instance.getInitialMessage();
                    if (initialMessage != null && initialMessage.data['type'] != null) {
                      // handleMessageClick(role: initialMessage.data['chatType'], type: initialMessage.data['type'], isBgApp: true);
                    } else {
                      Get.offAll(const DashBoardScreen());
                    }
                  } else {
                    await FirebaseAuth.instance.signOut();
                    Get.offAll(const LoginScreen());
                  }
                } else {
                  await FirebaseAuth.instance.signOut();
                  Get.offAll(const LoginScreen());
                }
              }
            });
          } else {
            await FirebaseAuth.instance.signOut();
            Get.offAll(const LoginScreen());
          }
        }
      } else {
        DashBoardController controller = Get.put(DashBoardController());
        controller.drawerIndex.value = 9;
        Get.offAll(DashBoardScreen());
      }
    }
  }
}
