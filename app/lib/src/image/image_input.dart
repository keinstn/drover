import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

class PickedImage {
  const PickedImage({required this.bytes, required this.extension});

  final Uint8List bytes;
  final String extension; // lowercase, no dot, e.g. 'png', 'jpg'
}

/// App-scoped interface for picking a single image. Returns null if the user
/// cancels.
abstract interface class ImagePickerPort {
  Future<PickedImage?> pickImage();
}

/// Backs [ImagePickerPort] with the image_picker plugin (photo library).
class SystemImagePicker implements ImagePickerPort {
  SystemImagePicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  @override
  Future<PickedImage?> pickImage() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final dot = file.name.lastIndexOf('.');
    final ext = dot == -1 ? 'png' : file.name.substring(dot + 1).toLowerCase();
    return PickedImage(bytes: bytes, extension: ext.isEmpty ? 'png' : ext);
  }
}
