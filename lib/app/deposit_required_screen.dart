import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:driver/constant/constant.dart';
import 'package:driver/constant/show_toast_dialog.dart';
import 'package:driver/themes/app_them_data.dart';
import 'package:driver/utils/dark_theme_provider.dart';
import 'package:driver/utils/fire_store_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

class DepositRequiredScreen extends StatefulWidget {
  const DepositRequiredScreen({super.key});

  @override
  State<DepositRequiredScreen> createState() => _DepositRequiredScreenState();
}

class _DepositRequiredScreenState extends State<DepositRequiredScreen> {
  bool _requestSent = false;

  Future<void> _submitDepositRequest(double cashBalance) async {
    ShowToastDialog.showLoader('Please wait'.tr);
    try {
      final uid = FireStoreUtils.getCurrentUid();
      final userData = Constant.userModel;
      await FireStoreUtils.fireStore.collection('cashDeposits').add({
        'driverId': uid,
        'driverName': userData?.fullName() ?? '',
        'driverPhone': '${userData?.countryCode ?? ''}${userData?.phoneNumber ?? ''}',
        'amount': cashBalance,
        'status': 'pending',
        'createdAt': Timestamp.now(),
        'note': 'Driver requested cash balance deposit review',
      });
      if (mounted) setState(() => _requestSent = true);
      ShowToastDialog.closeLoader();
      ShowToastDialog.showToast('Deposit request submitted'.tr);
    } catch (_) {
      ShowToastDialog.closeLoader();
      ShowToastDialog.showToast('Failed to submit request. Please try again.'.tr);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeChange = Provider.of<DarkThemeProvider>(context);
    final uid = FireStoreUtils.getCurrentUid();

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: themeChange.getThem() ? AppThemeData.surfaceDark : AppThemeData.surface,
        body: StreamBuilder<DocumentSnapshot>(
          stream: FireStoreUtils.fireStore.collection('users').doc(uid).snapshots(),
          builder: (context, snapshot) {
            final data = snapshot.data?.data() as Map<String, dynamic>?;
            final double cashBalance = (data?['cashBalance'] ?? 0).toDouble();
            final double limit = (data?['cashBalanceLimit'] ?? 300).toDouble();
            final String? blockedReason = data?['blockedReason'] as String?;

            if (snapshot.hasData && blockedReason != 'cash_limit_reached') {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && Navigator.canPop(context)) Get.back();
              });
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 32),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: const BoxDecoration(
                        color: AppThemeData.danger50,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.block_rounded, color: AppThemeData.danger300, size: 52),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Account Blocked'.tr,
                      style: const TextStyle(
                        fontFamily: AppThemeData.semiBold,
                        fontSize: 22,
                        color: AppThemeData.danger300,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'You have reached your cash balance limit. Please deposit the collected cash to continue receiving orders.'.tr,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: AppThemeData.regular,
                        fontSize: 15,
                        color: themeChange.getThem() ? AppThemeData.grey300 : AppThemeData.grey600,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: themeChange.getThem() ? AppThemeData.grey800 : AppThemeData.grey100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppThemeData.danger300.withValues(alpha: 0.4)),
                      ),
                      child: Column(
                        children: [
                          _infoRow(
                            'Cash Owed'.tr,
                            Constant.amountShow(amount: cashBalance.toString()),
                            AppThemeData.danger300,
                          ),
                          const SizedBox(height: 8),
                          _infoRow(
                            'Limit'.tr,
                            Constant.amountShow(amount: limit.toString()),
                            themeChange.getThem() ? AppThemeData.grey100 : AppThemeData.grey800,
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    if (_requestSent)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppThemeData.driverApp50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppThemeData.driverApp300.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle_rounded, color: AppThemeData.driverApp300),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Deposit request submitted. Admin will review and unblock your account.'.tr,
                                style: const TextStyle(
                                  fontFamily: AppThemeData.regular,
                                  fontSize: 14,
                                  color: AppThemeData.driverApp400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => _submitDepositRequest(cashBalance),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppThemeData.driverApp300,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            'Request Deposit Review'.tr,
                            style: const TextStyle(
                              fontFamily: AppThemeData.semiBold,
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontFamily: AppThemeData.regular, fontSize: 14, color: AppThemeData.grey600),
        ),
        Text(
          value,
          style: TextStyle(fontFamily: AppThemeData.semiBold, fontSize: 14, color: valueColor),
        ),
      ],
    );
  }
}
