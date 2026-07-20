import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

class PickedImage {
  const PickedImage({required this.bytes, required this.extension});

  final Uint8List bytes;
  final String extension; // lowercase, no dot, e.g. 'png', 'jpg'
}

/// Where an attached image comes from. Camera capture is only offered on
/// platforms that support it (iOS); the gallery is always available.
enum ImageAttachSource { gallery, camera }

/// App-scoped interface for picking images. Returns null (single) or an
/// empty list (multi) if the user cancels.
abstract interface class ImagePickerPort {
  Future<PickedImage?> pickImage(ImageAttachSource source);

  /// Picks one or more images from the gallery. Returns an empty list if the
  /// user cancels.
  Future<List<PickedImage>> pickImages();
}

/// Backs [ImagePickerPort] with the image_picker plugin.
class SystemImagePicker implements ImagePickerPort {
  SystemImagePicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  /// Picks a single image; used for both gallery and camera capture.
  @override
  Future<PickedImage?> pickImage(ImageAttachSource source) async {
    final file = await _picker.pickImage(
      source: source == ImageAttachSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
    );
    if (file == null) return null;
    return _toPickedImage(file);
  }

  @override
  Future<List<PickedImage>> pickImages() async {
    final files = await _picker.pickMultiImage();
    return [for (final file in files) await _toPickedImage(file)];
  }

  Future<PickedImage> _toPickedImage(XFile file) async {
    final bytes = await file.readAsBytes();
    final dot = file.name.lastIndexOf('.');
    final ext = dot == -1 ? 'png' : file.name.substring(dot + 1).toLowerCase();
    return PickedImage(bytes: bytes, extension: ext.isEmpty ? 'png' : ext);
  }
}
