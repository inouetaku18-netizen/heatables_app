class AutopilotController {
  static const int minPwm = 0;
  static const int maxPwm = 255;

  /// 心拍数に応じてPWM値を線形変換
  /// bpmがminHeartRate以下ならminPwm、maxHeartRate以上ならmaxPwm
  static int pwmFromHeartRate(
      double bpm, double minHeartRate, double maxHeartRate) {
    if (bpm <= minHeartRate) return minPwm;
    if (bpm >= maxHeartRate) return maxPwm;
    final ratio = (bpm - minHeartRate) / (maxHeartRate - minHeartRate);
    return (minPwm + ratio * (maxPwm - minPwm)).round();
  }
}
