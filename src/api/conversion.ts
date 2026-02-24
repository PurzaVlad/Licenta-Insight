import {NativeModules, Share} from "react-native";

const {ConversionService} = NativeModules;

export type ConversionResult = {
  outputPath: string;
  outputFilename: string;
};

export type ConversionDocumentResult = {
  outputUri: string;
  outputFilename: string;
};

export type ConversionErrorInfo = {
  message: string;
  errorCode?: string;
  httpStatus?: number;
};

const FRIENDLY_MESSAGES: Record<string, string> = {
  unauthorized: "You're not authorized to convert documents.",
  payload_too_large: "This file is too large to convert.",
  too_many_concurrent_conversions: "Too many conversions are in progress. Please try again shortly.",
  conversion_timed_out: "The conversion timed out. Please try again.",
  adobe_conversion_failed: "The conversion service failed. Please try again later.",
  libreoffice_conversion_failed: "The conversion service failed. Please try again later.",
  pdf_to_office_requires_adobe: "This conversion requires the Adobe backend. Please try a different format.",
};

export const healthCheck = async (): Promise<boolean> => {
  if (!ConversionService?.healthCheck) {
    return false;
  }
  return ConversionService.healthCheck();
};

const normalizeInputPath = (inputUri: string): string => {
  if (inputUri.startsWith("file://")) {
    return decodeURI(inputUri.replace("file://", ""));
  }
  return inputUri;
};

export const convertDocument = async (
  inputUri: string,
  targetExt: string,
  documentId?: string,
): Promise<ConversionDocumentResult> => {
  if (!ConversionService?.convertFile) {
    throw new Error("ConversionService native module is not available");
  }

  try {
    const inputPath = normalizeInputPath(inputUri);
    const result = (await ConversionService.convertFile(inputPath, targetExt, documentId ?? null)) as ConversionResult;
    const outputUri = result.outputPath.startsWith("file://")
      ? result.outputPath
      : `file://${result.outputPath}`;
    return {outputUri, outputFilename: result.outputFilename};
  } catch (error: any) {
    const mapped = mapConversionError(error);
    const friendlyMessage = mapped.errorCode && FRIENDLY_MESSAGES[mapped.errorCode]
      ? FRIENDLY_MESSAGES[mapped.errorCode]
      : mapped.message;

    const err = new Error(friendlyMessage) as Error & {
      code?: string;
      httpStatus?: number;
      raw?: unknown;
    };
    err.code = mapped.errorCode;
    err.httpStatus = mapped.httpStatus;
    err.raw = error;
    throw err;
  }
};

export const mapConversionError = (error: any): ConversionErrorInfo => {
  const errorCode = (error?.userInfo?.errorCode ?? error?.code ?? "") as string | undefined;
  const httpStatus = (error?.userInfo?.httpStatus ?? error?.httpStatus ?? undefined) as number | undefined;
  const message = error?.message ?? "Conversion failed";
  return {message, errorCode, httpStatus};
};

export const convertAndShareExample = async (inputDocxPath: string): Promise<ConversionDocumentResult> => {
  const result = await convertDocument(inputDocxPath, "pdf");
  await Share.share({
    url: result.outputUri,
    title: result.outputFilename,
  });
  return result;
};
