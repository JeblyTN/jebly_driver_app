import 'package:driver/constant/show_toast_dialog.dart';
import 'package:driver/models/user_model.dart';
import 'package:driver/utils/fire_store_utils.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class ForgotPasswordController extends GetxController {
  Rx<TextEditingController> emailEditingController = TextEditingController().obs;

  Future<void> forgotPassword() async {
    try {
      if (emailEditingController.value.text.trim().isEmpty) {
        ShowToastDialog.showToast("Please enter a valid email.".tr);
        return;
      }
      ShowToastDialog.showLoader("Please wait".tr);
      UserModel? userModel = await FireStoreUtils.getUserByEmailRole(emailEditingController.value.text);
      if (userModel?.provider != 'email') {
        ShowToastDialog.closeLoader();
        ShowToastDialog.showToast("This email address is not registered with an email and password.".tr);
        return;
      }
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: emailEditingController.value.text,
      );
      ShowToastDialog.closeLoader();
      ShowToastDialog.showToast('${'Reset Password link sent your'.tr} ${emailEditingController.value.text} ${'email'.tr}');
      Get.back();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') {
        ShowToastDialog.showToast('No user found for that email.'.tr);
      }
    }
  }
}
