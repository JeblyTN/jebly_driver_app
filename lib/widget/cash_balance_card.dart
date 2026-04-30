import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:driver/app/deposit_required_screen.dart';
import 'package:driver/constant/constant.dart';
import 'package:driver/themes/app_them_data.dart';
import 'package:driver/utils/dark_theme_provider.dart';
import 'package:driver/utils/fire_store_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

class CashBalanceCard extends StatelessWidget {
  const CashBalanceCard({super.key});

  @override
  Widget build(BuildContext context) {
    final themeChange = Provider.of<DarkThemeProvider>(context);
    final uid = FireStoreUtils.getCurrentUid();

    return StreamBuilder<DocumentSnapshot>(
      stream: FireStoreUtils.fireStore.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) return const SizedBox();

        final data = snapshot.data!.data() as Map<String, dynamic>?;
        if (data == null) return const SizedBox();

        final double cashBalance = (data['cashBalance'] ?? 0).toDouble();
        if (cashBalance <= 0) return const SizedBox();

        final double limit = (data['cashBalanceLimit'] ?? 300).toDouble();
        final String? blockedReason = data['blockedReason'] as String?;
        final bool isBlocked = blockedReason == 'cash_limit_reached';
        final double progress = limit > 0 ? (cashBalance / limit).clamp(0.0, 1.0) : 0.0;
        final bool isWarning = progress >= 0.8 && !isBlocked;

        final Color accentColor = isBlocked
            ? AppThemeData.danger300
            : isWarning
                ? AppThemeData.warning300
                : AppThemeData.driverApp300;

        final Color bgColor = isBlocked
            ? AppThemeData.danger50
            : isWarning
                ? AppThemeData.warning50
                : (themeChange.getThem() ? AppThemeData.grey800 : AppThemeData.grey100);

        return GestureDetector(
          onTap: () => Get.to(() => const DepositRequiredScreen()),
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accentColor.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isBlocked ? Icons.block_rounded : Icons.account_balance_wallet_outlined,
                      size: 16,
                      color: accentColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isBlocked ? 'Account Blocked'.tr : 'Cash Balance'.tr,
                      style: TextStyle(
                        fontFamily: AppThemeData.semiBold,
                        fontSize: 13,
                        color: isBlocked
                            ? AppThemeData.danger300
                            : themeChange.getThem()
                                ? AppThemeData.grey100
                                : AppThemeData.grey800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${Constant.amountShow(amount: cashBalance.toString())} / ${Constant.amountShow(amount: limit.toString())}',
                      style: TextStyle(
                        fontFamily: AppThemeData.semiBold,
                        fontSize: 13,
                        color: accentColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: themeChange.getThem() ? AppThemeData.grey700 : AppThemeData.grey200,
                    valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    minHeight: 6,
                  ),
                ),
                if (isBlocked) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Cash limit reached. Tap to request deposit review.'.tr,
                    style: const TextStyle(
                      fontFamily: AppThemeData.regular,
                      fontSize: 12,
                      color: AppThemeData.danger300,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
