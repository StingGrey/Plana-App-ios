import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/util/gallery_save.dart';

void main() {
  group('galleryImageFileName', () {
    test('按实际保存格式补后缀', () {
      expect(galleryImageFileName('plana_42', 'png'), 'plana_42.png');
      expect(galleryImageFileName('plana_42', '.JPG'), 'plana_42.jpg');
    });

    test('替换已有图片后缀,不产生双后缀', () {
      expect(galleryImageFileName('photo.png', 'png'), 'photo.png');
      expect(galleryImageFileName('photo.jpeg', 'jpg'), 'photo.jpg');
    });

    test('清理路径分隔符并为空名称提供回退', () {
      expect(galleryImageFileName(r'a/b\c', 'png'), 'a_b_c.png');
      expect(galleryImageFileName('', 'png'), 'image.png');
    });
  });
}
