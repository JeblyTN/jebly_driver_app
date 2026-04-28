import 'package:driver/controllers/splash_controller.dart';
import 'package:driver/themes/app_them_data.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<SplashController>(
      init: SplashController(),
      builder: (controller) {
        return Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Image.asset("assets/images/ic_logo.png", width: 150, height: 150),
                const SizedBox(height: 10,),
                Text(
                  "Welcome to Jebly Driver".tr,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black, fontSize: 28, fontFamily: AppThemeData.bold),
                ),
                Text(
                  "Your Favorite Food Delivered Fast!".tr,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black87),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
