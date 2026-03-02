import RNFS from "react-native-fs";

export const downloadModel = (
  modelName: string,
  modelUrl: string,
  onProgress: (progress: number) => void,
  hfToken?: string
): { promise: Promise<string>; cancel: () => void } => {
  const destPath = `${RNFS.DocumentDirectoryPath}/${modelName}`;

  let jobId: number | null = null;
  let cancelled = false;

  const promise = new Promise<string>((resolve, reject) => {
    if (!modelName || !modelUrl) {
      reject(new Error('Invalid model name or URL'));
      return;
    }

    console.log("Starting download from:", modelUrl);

    const headers: Record<string, string> = {};
    if (hfToken) {
      headers['Authorization'] = `Bearer ${hfToken}`;
    }

    const downloadTask = RNFS.downloadFile({
      fromUrl: modelUrl,
      toFile: destPath,
      progressDivider: 5,
      headers: Object.keys(headers).length > 0 ? headers : undefined,
      begin: (res) => {
        jobId = res.jobId;
        console.log("Download started:", res);
      },
      progress: ({ bytesWritten, contentLength }: { bytesWritten: number; contentLength: number }) => {
        if (cancelled) return;
        const progress = (bytesWritten / contentLength) * 100;
        console.log("Download progress:", progress);
        onProgress(Math.floor(progress));
      },
    });

    downloadTask.promise.then((result) => {
      if (cancelled) {
        reject(new Error('Download cancelled'));
        return;
      }
      if (result.statusCode === 200) {
        resolve(destPath);
      } else {
        reject(new Error(`Download failed with status code: ${result.statusCode}`));
      }
    }).catch((error) => {
      if (cancelled) {
        reject(new Error('Download cancelled'));
      } else {
        reject(new Error(`Failed to download model: ${error instanceof Error ? error.message : 'Unknown error'}`));
      }
    });
  });

  const cancel = () => {
    cancelled = true;
    if (jobId !== null) {
      try { RNFS.stopDownload(jobId); } catch {}
    }
  };

  return { promise, cancel };
};
