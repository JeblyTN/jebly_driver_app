// home_controller.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:driver/app/deposit_required_screen.dart';
import 'package:driver/constant/collection_name.dart';
import 'package:driver/constant/constant.dart';
import 'package:driver/constant/send_notification.dart';
import 'package:driver/constant/show_toast_dialog.dart';
import 'package:driver/models/order_model.dart';
import 'package:driver/models/user_model.dart';
import 'package:driver/services/audio_player_service.dart';
import 'package:driver/themes/app_them_data.dart';
import 'package:driver/utils/fire_store_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as flutterMap;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' as gmaps;
import 'package:latlong2/latlong.dart' as location;

/// HomeController - optimized for smooth marker animation and reduced rebuilds
class HomeController extends GetxController {
  // ======= reactive / state =========
  RxBool isLoading = true.obs;

  // OSM
  flutterMap.MapController osmMapController = flutterMap.MapController();
  RxList<flutterMap.Marker> osmMarkers = <flutterMap.Marker>[].obs;

  // Current models
  Rx<OrderModel> orderModel = OrderModel().obs;
  Rx<OrderModel> currentOrder = OrderModel().obs;
  Rx<UserModel> driverModel = UserModel().obs;

  // Google
  GoogleMapController? mapController;

  // polyline/directions for Google
  Rx<PolylinePoints> polylinePoints = PolylinePoints(apiKey: Constant.mapAPIKey).obs;
  RxMap<PolylineId, Polyline> polyLines = <PolylineId, Polyline>{}.obs;
  RxMap<String, Marker> markers = <String, Marker>{}.obs;

  // OSM route points
  RxList<location.LatLng> routePoints = <location.LatLng>[].obs;

  // Icons
  BitmapDescriptor? departureIcon;
  BitmapDescriptor? destinationIcon;
  BitmapDescriptor? taxiIcon;

  // OSM markers & positions (reactive)
  Rx<location.LatLng> source = location.LatLng(21.1702, 72.8311).obs;
  Rx<location.LatLng> current = location.LatLng(21.1800, 72.8400).obs;
  Rx<location.LatLng> destination = location.LatLng(21.2000, 72.8600).obs;

  RxBool isChange = false.obs;

  // internal animation keys to cancel running loops
  int _googleAnimKey = 0;
  int _osmAnimKey = 0;

  // last positions used to compute movement/distance threshold
  gmaps.LatLng? _oldGooglePos;
  location.LatLng? _oldOsmPos;

  // subscriptions
  StreamSubscription? _driverSub;
  StreamSubscription? _orderSub;

  // Camera follow throttle
  DateTime _lastCameraFollow = DateTime.fromMillisecondsSinceEpoch(0);
  final Duration cameraFollowThrottle = const Duration(milliseconds: 200);

  // Movement threshold (meters) below which we snap instead of animate
  final double snapThresholdMeters = 0.8;

  @override
  void onInit() {
    super.onInit();
    getArgument();
    setIcons();
    getDriver();
  }

  @override
  void onClose() {
    // cancel running animations/streams
    _googleAnimKey++;
    _osmAnimKey++;
    _driverSub?.cancel();
    _orderSub?.cancel();
    mapController = null;
    super.onClose();
  }

  // -------------------------
  // Arguments
  // -------------------------
  void getArgument() {
    try {
      final dynamic argumentData = Get.arguments;
      if (argumentData != null && argumentData['orderModel'] != null) {
        orderModel.value = argumentData['orderModel'];
      }
    } catch (_) {}
  }

  bool _depositScreenPushed = false;

  // -------------------------
  // Order actions
  // -------------------------
  Future<void> acceptOrder() async {
    if (driverModel.value.blockedReason == 'cash_limit_reached') {
      if (!_depositScreenPushed) {
        _depositScreenPushed = true;
        Get.to(() => const DepositRequiredScreen())?.then((_) => _depositScreenPushed = false);
      }
      return;
    }
    ShowToastDialog.showLoader("Please wait".tr);
    await AudioPlayerService.playSound(false);
    driverModel.value.inProgressOrderID ??= [];
    driverModel.value.orderRequestData?.remove(currentOrder.value.id);
    driverModel.value.inProgressOrderID!.add(currentOrder.value.id);

    await FireStoreUtils.updateUser(driverModel.value);

    currentOrder.value.status = Constant.driverAccepted;
    currentOrder.value.driverID = driverModel.value.id;
    currentOrder.value.driver = driverModel.value;

    await FireStoreUtils.setOrder(currentOrder.value);

    await SendNotification.sendFcmMessage(Constant.driverAcceptedNotification, currentOrder.value.author!.fcmToken.toString(), {});
    await SendNotification.sendFcmMessage(Constant.driverAcceptedNotification, currentOrder.value.vendor!.fcmToken.toString(), {});
    ShowToastDialog.closeLoader();
  }

  Future<void> rejectOrder() async {
    ShowToastDialog.showLoader("Please wait".tr);
    await AudioPlayerService.playSound(false);

    currentOrder.value.rejectedByDrivers ??= [];
    currentOrder.value.rejectedByDrivers!.add(driverModel.value.id);
    currentOrder.value.status = Constant.driverRejected;
    await FireStoreUtils.setOrder(currentOrder.value);

    driverModel.value.orderRequestData?.remove(currentOrder.value.id);
    await FireStoreUtils.updateUser(driverModel.value);

    currentOrder.value = OrderModel();
    await clearMap();

    if (Constant.singleOrderReceive == false) {
      Get.back();
    }
    ShowToastDialog.closeLoader();
  }

  Future<void> clearMap() async {
    await AudioPlayerService.playSound(false);
    if (Constant.selectedMapType != 'osm') {
      markers.clear();
      polyLines.clear();
    } else {
      osmMarkers.clear();
      routePoints.clear();
    }
    update();
    getDriver();
  }

  // -------------------------
  // Driver & order listeners
  // -------------------------
  void getDriver() {
    final uid = FireStoreUtils.getCurrentUid();
    if (uid.isEmpty || uid == '') {
      isLoading.value = false;
      update();
      return;
    }

    _driverSub?.cancel();
    _driverSub = FireStoreUtils.fireStore.collection(CollectionName.users).doc(uid).snapshots().listen(
      (event) async {
        if (event.exists) {
          driverModel.value = UserModel.fromJson(event.data()!);
          if (driverModel.value.id != null) {
            isLoading.value = false;
            update();
            if (driverModel.value.blockedReason == 'cash_limit_reached' && !_depositScreenPushed) {
              _depositScreenPushed = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                Get.to(() => const DepositRequiredScreen())?.then((_) => _depositScreenPushed = false);
              });
            }
            changeData();
            // Setup current order listener depending on state (singleOrderReceive or provided orderModel)
            _setupOrderListener();
          }
        }
      },
      onError: (e) {
        print("Driver listener error: $e");
      },
    );
  }

  Future<void> _setupOrderListener() async {
    // Cancel previous order subscription
    _orderSub?.cancel();

    // Determine order id to listen to: priority -> inProgress -> orderRequestData -> passed argument orderModel
    String? orderId = '';
    if (driverModel.value.inProgressOrderID != null && driverModel.value.inProgressOrderID!.isNotEmpty) {
      orderId = driverModel.value.inProgressOrderID!.first.toString();
    } else if (driverModel.value.orderRequestData != null && driverModel.value.orderRequestData!.isNotEmpty) {
      orderId = driverModel.value.orderRequestData!.first.toString();
    } else if (orderModel.value.id != null) {
      orderId = orderModel.value.id.toString();
    } else if (orderId == '') {
      currentOrder.value = OrderModel();
      clearMap();
      await AudioPlayerService.playSound(false);
    }

    if (orderId == '' || orderId.isEmpty) {
      if (Constant.selectedMapType == 'osm') {
        osmMarkers.value = [
          flutterMap.Marker(
            point: location.LatLng(driverModel.value.location!.latitude!, driverModel.value.location!.longitude!),
            width: 45,
            height: 45,
            rotate: true,
            child: Transform.rotate(
              angle: double.parse(driverModel.value.rotation.toString()) * (math.pi / 180),
              child: Image.asset('assets/images/food_delivery.png'),
            ),
          )
        ];
      } else {
        markers['Driver'] = Marker(
          markerId: const MarkerId('Driver'),
          position: LatLng(driverModel.value.location!.latitude!, driverModel.value.location!.longitude!),
          icon: taxiIcon ?? BitmapDescriptor.defaultMarker,
          anchor: const Offset(0.5, 0.5),
        );
      }
      return;
    }

    _orderSub = FireStoreUtils.fireStore
        .collection(CollectionName.restaurantOrders)
        .where('status', whereNotIn: [Constant.orderCancelled, Constant.driverRejected])
        .where('id', isEqualTo: orderId)
        .limit(1)
        .snapshots()
        .listen(
          (snap) async {
            if (snap.docs.isNotEmpty) {
              final newOrder = OrderModel.fromJson(snap.docs.first.data());
              // Update only if changed (reduce unnecessary processing)
              // if (currentOrder.value.id != newOrder.id || currentOrder.value.status != newOrder.status) {
              currentOrder.value = newOrder;
              changeData();
              // }
            } else {
              if (Constant.selectedMapType == 'osm') {
                final flutterMap.Marker driverMarker = flutterMap.Marker(
                  point: location.LatLng(driverModel.value.location!.latitude!, driverModel.value.location!.longitude!),
                  width: 45,
                  height: 45,
                  rotate: true,
                  child: Transform.rotate(
                    angle: double.parse(driverModel.value.rotation.toString()) * (math.pi / 180),
                    child: Image.asset('assets/images/food_delivery.png'),
                  ),
                );
                osmMarkers.value = [driverMarker];
              } else {
                markers['Driver'] = Marker(
                  markerId: const MarkerId('Driver'),
                  position: LatLng(driverModel.value.location!.latitude!, driverModel.value.location!.longitude!),
                  icon: taxiIcon ?? BitmapDescriptor.defaultMarker,
                  anchor: const Offset(0.5, 0.5),
                );
              }
              // Order removed or not found
              currentOrder.value = OrderModel();
              await AudioPlayerService.playSound(false);
              update();
            }
          },
          onError: (e) {
            print("Order listener error: $e");
          },
        );
  }

  // -------------------------
  // Change data (trigger when order changes)
  // -------------------------
  Future<void> changeData() async {
    // Debug log
    print("currentOrder.value.status :: ${currentOrder.value.id} :: ${currentOrder.value.status}");

    // Build directions / route
    if (Constant.mapType == "inappmap") {
      if (Constant.selectedMapType == "osm") {
        await getOSMPolyline();
      } else {
        await getDirections();
      }
    }

    // Play a sound for pending
    if (currentOrder.value.status == Constant.driverPending) {
      await AudioPlayerService.playSound(true);
    } else {
      await AudioPlayerService.playSound(false);
    }
  }

  // -------------------------
  // Map icons
  // -------------------------
  Future<void> setIcons() async {
    try {
      if (Constant.selectedMapType == 'google') {
        final Uint8List departure = await Constant().getBytesFromAsset('assets/images/location_black3x.png', 100);
        final Uint8List destination = await Constant().getBytesFromAsset('assets/images/location_orange3x.png', 100);
        final Uint8List driver = await Constant().getBytesFromAsset('assets/images/food_delivery.png', 100);

        departureIcon = BitmapDescriptor.fromBytes(departure);
        destinationIcon = BitmapDescriptor.fromBytes(destination);
        taxiIcon = BitmapDescriptor.fromBytes(driver);
      }
    } catch (e) {
      print("setIcons error: $e");
    }
  }

  // -------------------------
  // Smooth animation helpers
  // -------------------------
  gmaps.LatLng _lerpLatLng(gmaps.LatLng a, gmaps.LatLng b, double t) {
    return gmaps.LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
  }

  location.LatLng _lerpOsmLatLng(location.LatLng a, location.LatLng b, double t) {
    return location.LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
  }

  double _interpolateRotation(double start, double end, double t) {
    double diff = (end - start) % 360;
    if (diff < -180) diff += 360;
    if (diff > 180) diff -= 360;
    return (start + diff * t) % 360;
  }

  double _deg2rad(double deg) => deg * (math.pi / 180);

  double _calculateDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371000;
    final double dLat = _deg2rad(lat2 - lat1);
    final double dLon = _deg2rad(lon2 - lon1);
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(_deg2rad(lat1)) * math.cos(_deg2rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    final double d = R * c;
    return d;
  }

  // -------------------------
  // Animate Google Marker (optimized)
  // -------------------------
  Future<void> animateDriverMarkerGoogle(
    gmaps.LatLng newPos, {
    double? newRotation,
    Duration duration = const Duration(milliseconds: 450),
    bool followCamera = true,
  }) async {
    final int myKey = ++_googleAnimKey;
    final gmaps.LatLng from = _oldGooglePos ?? newPos;

    final double distanceMeters = _calculateDistanceMeters(from.latitude, from.longitude, newPos.latitude, newPos.longitude);
    // Avoid micro-churn
    if (distanceMeters <= snapThresholdMeters) {
      // set final immediately
      markers['Driver'] = Marker(
        markerId: const MarkerId('Driver'),
        position: LatLng(newPos.latitude, newPos.longitude),
        icon: taxiIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
      );
      _oldGooglePos = newPos;
      if (followCamera && DateTime.now().difference(_lastCameraFollow) > cameraFollowThrottle) {
        _lastCameraFollow = DateTime.now();
        try {
          mapController?.animateCamera(CameraUpdate.newLatLng(LatLng(newPos.latitude, newPos.longitude)));
        } catch (_) {}
      }
      update();
      return;
    }

    final int fps = 60;
    final int totalFrames = (duration.inMilliseconds / (1000 / fps)).round().clamp(1, 999);
    final double startRotation = double.tryParse(driverModel.value.rotation.toString()) ?? 0.0;
    final double targetRotation = newRotation ?? startRotation;

    for (int i = 0; i <= totalFrames; i++) {
      if (myKey != _googleAnimKey) return;

      final double tRaw = (i / totalFrames).clamp(0.0, 1.0);
      final double t = Curves.easeInOut.transform(tRaw);

      final gmaps.LatLng interpolated = _lerpLatLng(from, newPos, t);
      final double rot = _interpolateRotation(startRotation, targetRotation, t);

      // update marker position (recreate marker but avoid heavy UI updates)
      markers['Driver'] = Marker(
        markerId: const MarkerId('Driver'),
        position: LatLng(interpolated.latitude, interpolated.longitude),
        icon: taxiIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        flat: true,
        rotation: rot,
      );

      // move camera less frequently (every 3 frames)
      if (followCamera && (i % 3 == 0) && DateTime.now().difference(_lastCameraFollow) > cameraFollowThrottle) {
        _lastCameraFollow = DateTime.now();
        try {
          mapController?.animateCamera(CameraUpdate.newLatLng(LatLng(interpolated.latitude, interpolated.longitude)));
        } catch (_) {}
      }

      // reduce rebuild rate: update UI only every 2 frames
      if (i % 2 == 0) update();

      await Future.delayed(Duration(milliseconds: (1000 / fps).round()));
    }

    if (myKey == _googleAnimKey) {
      markers['Driver'] = Marker(
        markerId: const MarkerId('Driver'),
        position: LatLng(newPos.latitude, newPos.longitude),
        icon: taxiIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        flat: true,
        rotation: newRotation ?? double.tryParse(driverModel.value.rotation.toString()) ?? 0.0,
      );
      _oldGooglePos = newPos;
      update();
    }
  }

  // -------------------------
  // OSM Animation (optimized)
  // -------------------------
  Future<void> animateDriverMarkerOsm(
    location.LatLng newPos, {
    double? newRotation,
    Duration duration = const Duration(milliseconds: 1000),
    double osmZoom = 14.0,
    bool followCamera = true,
    int cameraUpdateEveryNthFrame = 3,
  }) async {
    final int myKey = ++_osmAnimKey;
    final location.LatLng from = _oldOsmPos ?? newPos;

    final double startRot = double.tryParse(driverModel.value.rotation.toString()) ?? 0.0;
    final double targetRot = newRotation ?? startRot;

    final double distanceMeters = _calculateDistanceMeters(from.latitude, from.longitude, newPos.latitude, newPos.longitude);
    if (distanceMeters <= snapThresholdMeters) {
      _setOsmDriverMarker(newPos, targetRot);
      _oldOsmPos = newPos;
      if (followCamera && DateTime.now().difference(_lastCameraFollow) > cameraFollowThrottle) {
        _lastCameraFollow = DateTime.now();
        try {
          osmMapController.move(newPos, osmZoom);
        } catch (_) {}
      }
      return;
    }

    final int fps = 60;
    final int totalFrames = (duration.inMilliseconds / (1000 / fps)).round().clamp(1, 999);

    for (int i = 0; i <= totalFrames; i++) {
      if (myKey != _osmAnimKey) return;

      final double tRaw = (i / totalFrames).clamp(0.0, 1.0);
      final double t = Curves.easeInOut.transform(tRaw);

      final location.LatLng interpolated = _lerpOsmLatLng(from, newPos, t);
      final double rot = _interpolateRotation(startRot, targetRot, t);

      // update marker but throttle UI updates
      _setOsmDriverMarker(interpolated, rot, triggerUpdate: (i % 2 == 0));

      if (followCamera && (i % cameraUpdateEveryNthFrame == 0) && DateTime.now().difference(_lastCameraFollow) > cameraFollowThrottle) {
        _lastCameraFollow = DateTime.now();
        try {
          osmMapController.move(interpolated, osmZoom);
        } catch (_) {}
      }

      await Future.delayed(Duration(milliseconds: (1000 / fps).round()));
    }

    if (myKey == _osmAnimKey) {
      _setOsmDriverMarker(newPos, targetRot);
      _oldOsmPos = newPos;
    }
  }

  /// OSM marker setter (creates full list of markers but assigns atomically)
  void _setOsmDriverMarker(location.LatLng pos, double rotation, {bool triggerUpdate = true}) {
    try {
      final flutterMap.Marker driverMarker = flutterMap.Marker(
        point: pos,
        width: 45,
        height: 45,
        rotate: true,
        child: Transform.rotate(
          angle: rotation * (math.pi / 180),
          child: Image.asset('assets/images/food_delivery.png'),
        ),
      );

      final flutterMap.Marker sourceMarker = flutterMap.Marker(
        point: source.value,
        width: 40,
        height: 40,
        child: Image.asset('assets/images/location_black3x.png'),
      );

      final flutterMap.Marker destinationMarker = flutterMap.Marker(
        point: destination.value,
        width: 40,
        height: 40,
        child: Image.asset('assets/images/location_orange3x.png'),
      );

      // assign list in one go
      osmMarkers.value = [driverMarker, sourceMarker, destinationMarker];

      if (triggerUpdate) update();
    } catch (e) {
      print("Error _setOsmDriverMarker: $e");
    }
  }

  Future<void> getDirections() async {
    try {
      if (currentOrder.value.id == null) return;

      // Build origin & destination depending on order status
      PointLatLng origin;
      PointLatLng dest;

      if (currentOrder.value.status != Constant.driverPending) {
        if (currentOrder.value.status == Constant.orderShipped) {
          origin = PointLatLng(driverModel.value.location?.latitude ?? 0.0, driverModel.value.location?.longitude ?? 0.0);
          dest = PointLatLng(currentOrder.value.vendor?.latitude ?? 0.0, currentOrder.value.vendor?.longitude ?? 0.0);
        } else if (currentOrder.value.status == Constant.orderInTransit) {
          origin = PointLatLng(driverModel.value.location?.latitude ?? 0.0, driverModel.value.location?.longitude ?? 0.0);
          dest = PointLatLng(currentOrder.value.address?.location?.latitude ?? 0.0, currentOrder.value.address?.location?.longitude ?? 0.0);
        } else {
          // fallback
          origin = PointLatLng(driverModel.value.location?.latitude ?? 0.0, driverModel.value.location?.longitude ?? 0.0);
          dest = PointLatLng(currentOrder.value.vendor?.latitude ?? 0.0, currentOrder.value.vendor?.longitude ?? 0.0);
        }
      } else {
        origin = PointLatLng(currentOrder.value.author?.location?.latitude ?? 0.0, currentOrder.value.author?.location?.longitude ?? 0.0);
        dest = PointLatLng(currentOrder.value.vendor?.latitude ?? 0.0, currentOrder.value.vendor?.longitude ?? 0.0);
      }

      final PolylineResult result = await polylinePoints.value.getRouteBetweenCoordinates(
        request: PolylineRequest(origin: origin, destination: dest, mode: TravelMode.driving),
      );

      List<LatLng> polylineCoordinates = [];
      if (result.points.isNotEmpty) {
        for (var point in result.points) {
          polylineCoordinates.add(LatLng(point.latitude, point.longitude));
        }
      }

      // update map markers & polyline depending on status
      if (currentOrder.value.status == Constant.orderShipped) {
        markers.remove("Departure");
        markers['Departure'] = Marker(
            markerId: const MarkerId('Departure'),
            infoWindow: const InfoWindow(title: "Departure"),
            position: LatLng(currentOrder.value.vendor!.latitude ?? 0.0, currentOrder.value.vendor!.longitude ?? 0.0),
            icon: departureIcon ?? BitmapDescriptor.defaultMarker);
      } else if (currentOrder.value.status == Constant.orderInTransit) {
        markers.remove("Departure");
        markers['Destination'] = Marker(
            markerId: const MarkerId('Destination'),
            infoWindow: const InfoWindow(title: "Destination"),
            position: LatLng(currentOrder.value.address!.location!.latitude ?? 0.0, currentOrder.value.address!.location!.longitude ?? 0.0),
            icon: destinationIcon ?? BitmapDescriptor.defaultMarker);
      } else if (currentOrder.value.status == Constant.driverPending) {
        markers.remove("Departure");
        markers['Departure'] = Marker(
            markerId: const MarkerId('Departure'),
            infoWindow: const InfoWindow(title: "Departure"),
            position: LatLng(currentOrder.value.vendor!.latitude ?? 0.0, currentOrder.value.vendor!.longitude ?? 0.0),
            icon: departureIcon ?? BitmapDescriptor.defaultMarker);

        markers.remove("Destination");
        markers['Destination'] = Marker(
            markerId: const MarkerId('Destination'),
            infoWindow: const InfoWindow(title: "Destination"),
            position: LatLng(currentOrder.value.address!.location!.latitude ?? 0.0, currentOrder.value.address!.location!.longitude ?? 0.0),
            icon: destinationIcon ?? BitmapDescriptor.defaultMarker);
      }

      // ensure driver marker present
      markers['Driver'] = Marker(
        markerId: const MarkerId('Driver'),
        position: LatLng(driverModel.value.location!.latitude ?? 0.0, driverModel.value.location!.longitude ?? 0.0),
        icon: taxiIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
      );

      // animate to driver's current location (non-blocking)
      animateDriverMarkerGoogle(
        gmaps.LatLng(driverModel.value.location!.latitude ?? 0.0, driverModel.value.location!.longitude ?? 0.0),
        newRotation: double.tryParse(driverModel.value.rotation.toString()) ?? 0.0,
      );

      addPolyLine(polylineCoordinates);
    } catch (e) {
      print("getDirections error: $e");
    }
  }

  void addPolyLine(List<LatLng> polylineCoordinates) {
    try {
      PolylineId id = const PolylineId("poly");
      Polyline polyline = Polyline(
        polylineId: id,
        color: AppThemeData.secondary300,
        points: polylineCoordinates,
        width: 8,
        geodesic: true,
      );
      polyLines[id] = polyline;
      update();
      if (polylineCoordinates.isNotEmpty) updateCameraLocation(polylineCoordinates.first, mapController);
    } catch (e) {
      print("addPolyLine error: $e");
    }
  }

  Future<void> updateCameraLocation(LatLng source, GoogleMapController? mapController) async {
    if (mapController == null) return;
    try {
      await mapController.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(Constant.locationDataFinal?.latitude ?? 0.0, Constant.locationDataFinal?.longitude ?? 0.0),
            zoom: 16,
            bearing: double.parse('${driverModel.value.rotation ?? '0.0'}'),
          ),
        ),
      );
    } catch (e) {
      print("updateCameraLocation error: $e");
    }
  }

  // -------------------------
  // OSM helpers
  // -------------------------
  void setOsmMapMarker() {
    final driverMarker = flutterMap.Marker(
        point: current.value,
        width: 45,
        height: 45,
        rotate: true,
        child: Transform.rotate(angle: double.parse(driverModel.value.rotation.toString()) * (math.pi / 180), child: Image.asset('assets/images/food_delivery.png')));
    final src = flutterMap.Marker(point: source.value, width: 40, height: 40, child: Image.asset('assets/images/location_black3x.png'));
    final dst = flutterMap.Marker(point: destination.value, width: 40, height: 40, child: Image.asset('assets/images/location_orange3x.png'));

    osmMarkers.value = [driverMarker, src, dst];
    update();
  }

  Future<void> getOSMPolyline() async {
    try {
      if (currentOrder.value.id == null) return;
      if (currentOrder.value.status != Constant.driverPending) {
        if (currentOrder.value.status == Constant.orderShipped || currentOrder.value.status == Constant.driverAccepted) {
          current.value = location.LatLng(driverModel.value.location?.latitude ?? 0.0, driverModel.value.location?.longitude ?? 0.0);
          destination.value = location.LatLng(currentOrder.value.vendor?.latitude ?? 0.0, currentOrder.value.vendor?.longitude ?? 0.0);
          await fetchRoute(current.value, destination.value);
          updateOMSDriverLocation(lat: driverModel.value.location?.latitude ?? 0.0, lng: driverModel.value.location?.longitude ?? 0.0, rotation: double.parse("${driverModel.value.rotation ?? 0.0}"));
        } else if (currentOrder.value.status == Constant.orderInTransit) {
          current.value = location.LatLng(driverModel.value.location?.latitude ?? 0.0, driverModel.value.location?.longitude ?? 0.0);
          destination.value = location.LatLng(currentOrder.value.address?.location?.latitude ?? 0.0, currentOrder.value.address?.location?.longitude ?? 0.0);
          await fetchRoute(current.value, destination.value);
          updateOMSDriverLocation(lat: driverModel.value.location?.latitude ?? 0.0, lng: driverModel.value.location?.longitude ?? 0.0, rotation: double.parse("${driverModel.value.rotation ?? 0.0}"));
        }
      } else {
        current.value = location.LatLng(currentOrder.value.author?.location?.latitude ?? 0.0, currentOrder.value.author?.location?.longitude ?? 0.0);
        destination.value = location.LatLng(currentOrder.value.vendor?.latitude ?? 0.0, currentOrder.value.vendor?.longitude ?? 0.0);
        await fetchRoute(current.value, destination.value);
        updateOMSDriverLocation(lat: driverModel.value.location?.latitude ?? 0.0, lng: driverModel.value.location?.longitude ?? 0.0, rotation: double.parse("${driverModel.value.rotation ?? 0.0}"));
      }
    } catch (e) {
      print('getOSMPolyline Error: $e');
    }
  }

  Future<void> fetchRoute(location.LatLng source, location.LatLng destination) async {
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${source.longitude},${source.latitude};'
        '${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson&continue_straight=false',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        final geometry = decoded['routes'][0]['geometry']['coordinates'];

        List<location.LatLng> temp = [];

        for (var coord in geometry) {
          temp.add(location.LatLng(coord[1], coord[0]));
        }

        // Smooth points
        routePoints.value = smoothRoute(temp);

        update();
      } else {
        print("Failed to get route: ${response.body}");
      }
    } catch (e) {
      print("fetchRoute error: $e");
    }
  }

  List<location.LatLng> smoothRoute(List<location.LatLng> points) {
    if (points.length < 3) return points;

    final smoothed = <location.LatLng>[];
    for (int i = 1; i < points.length - 1; i++) {
      final p1 = points[i - 1];
      final p2 = points[i];
      final p3 = points[i + 1];

      final dx1 = p2.latitude - p1.latitude;
      final dy1 = p2.longitude - p1.longitude;
      final dx2 = p3.latitude - p2.latitude;
      final dy2 = p3.longitude - p2.longitude;

      final dot = dx1 * dx2 + dy1 * dy2;
      if (dot > 0) smoothed.add(p2);
    }

    return smoothed;
  }

  // -------------------------
  // Misc helpers
  // -------------------------
  /// Public method for updating map marker based on a controlled logic (avoids micro updates)
  void updateOMSDriverLocation({required double lat, required double lng, required double rotation}) {
    final newPosGoogle = gmaps.LatLng(lat, lng);
    final newPosOsm = location.LatLng(lat, lng);

    // Avoid micro-updates (< snapThresholdMeters)
    final last = _oldGooglePos;
    if (last != null) {
      final dist = _calculateDistanceMeters(last.latitude, last.longitude, lat, lng);
      if (dist < snapThresholdMeters) return;
    }

    if (Constant.selectedMapType == 'google') {
      animateDriverMarkerGoogle(newPosGoogle, newRotation: rotation, duration: const Duration(milliseconds: 450), followCamera: true);
    } else {
      animateDriverMarkerOsm(newPosOsm, newRotation: rotation, duration: const Duration(milliseconds: 900), followCamera: true, cameraUpdateEveryNthFrame: 4);
    }
  }

  /// Wrapper to call when driver location updates are received externally
  Future<void> onDriverLocationUpdate({double? lat, double? lng, double? rotation}) async {
    if (lat == null || lng == null) return;
    if (Constant.selectedMapType == 'google') {
      await animateDriverMarkerGoogle(gmaps.LatLng(lat, lng), newRotation: rotation ?? (double.tryParse(driverModel.value.rotation.toString()) ?? 0.0));
    } else {
      await animateDriverMarkerOsm(location.LatLng(lat, lng), newRotation: rotation ?? (double.tryParse(driverModel.value.rotation.toString()) ?? 0.0));
    }
  }
}
