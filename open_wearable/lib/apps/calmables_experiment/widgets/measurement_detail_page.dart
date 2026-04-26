import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:share_plus/share_plus.dart';

class MeasurementDetailPage extends StatelessWidget {
  final String? pwmFilePath;
  final String? ppgFilePath;
  final String? hrFilePath;
  final double? averageHeartRate;

  const MeasurementDetailPage({
    super.key,
    required this.pwmFilePath,
    required this.ppgFilePath,
    required this.hrFilePath,
    required this.averageHeartRate,
  });

  Future<void> _shareFile(BuildContext context, String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The file does not exist.')),
      );
      return;
    }
    await Share.shareXFiles([XFile(filePath)]);
  }

  Future<void> _deleteFile(BuildContext context, String filePath) async {
    //if (filePath == null) return;
    final file = File(filePath);
    if (!await file.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The file has already been deleted.')),
      );
      return;
    }
    try {
      await file.delete();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The file has been deleted.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e')),
      );
    }
  }

  Future<void> _shareZip(BuildContext context) async {
    try {
      final files = <File>[];
      if (pwmFilePath != null && await File(pwmFilePath!).exists()) {
        files.add(File(pwmFilePath!));
      }
      if (ppgFilePath != null && await File(ppgFilePath!).exists()) {
        files.add(File(ppgFilePath!));
      }
      if (hrFilePath != null && await File(hrFilePath!).exists()) {
        files.add(File(hrFilePath!));
      }
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No files available to share.')),
        );
        return;
      }

      // 一時ディレクトリ取得
      final tempDir = await getTemporaryDirectory();

      // ZIPファイルパス
      final zipFilePath = p.join(tempDir.path, 'measurement_data.zip');
      final zipFile = File(zipFilePath);

      // 既存のZIPファイルがあれば削除
      if (await zipFile.exists()) {
        await zipFile.delete();
      }

      // ZIP用の一時ディレクトリを作成
      final zipSourceDir = Directory(p.join(tempDir.path, 'zip_source'));
      if (await zipSourceDir.exists()) {
        await zipSourceDir.delete(recursive: true);
      }
      await zipSourceDir.create();

      // ファイルを一時ディレクトリにコピー
      for (final file in files) {
        final newPath = p.join(zipSourceDir.path, p.basename(file.path));
        await file.copy(newPath);
      }

      // ZIP作成（サブディレクトリも含める）
      await ZipFile.createFromDirectory(
        sourceDir: zipSourceDir,
        zipFile: zipFile,
        recurseSubDirs: false,
      );

      // ZIP共有
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(zipFile.path)],
          subject: 'Measurement Data ZIP',
        ),
      );

      // 後片付け：ZIPファイルとコピー元一時フォルダ削除
      if (await zipFile.exists()) {
        await zipFile.delete();
      }
      if (await zipSourceDir.exists()) {
        await zipSourceDir.delete(recursive: true);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create and share the Zip file: $e')),
      );
    }
  }

  Widget _buildFileTile(BuildContext context, String label, String? filePath) {
    final fileName = filePath != null ? p.basename(filePath) : '--';
    return Card(
      child: ListTile(
        title: Text(label),
        subtitle: Text(fileName),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.share),
              onPressed:
                  filePath != null ? () => _shareFile(context, filePath) : null,
              tooltip: 'Share',
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: filePath != null
                  ? () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Delete recording?'),
                          content:
                              Text('This will permanently delete "$fileName"'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel')),
                            TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await _deleteFile(context, filePath);
                      }
                    }
                  : null,
              tooltip: 'Delete',
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Measurement Data Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.archive),
            tooltip: 'Share all files as ZIP',
            onPressed: () => _shareZip(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('Average Heart Rate'),
            trailing: Text(
              averageHeartRate != null
                  ? '${averageHeartRate!.toStringAsFixed(1)} BPM'
                  : '--',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
          const Divider(),
          _buildFileTile(context, 'PWM.csv', pwmFilePath),
          _buildFileTile(context, 'PPG.csv', ppgFilePath),
          _buildFileTile(context, 'HeartRate.csv', hrFilePath),
        ],
      ),
    );
  }
}
