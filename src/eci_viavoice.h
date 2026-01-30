/*====================================================================================*/
/*                                                                                    */
/*   eci.h                                                                            */
/*                                                                                    */
/*   (C) COPYRIGHT International Business Machines Corp. 1998, 2000                   */
/*   All Rights Reserved                                                              */
/*   Licensed Materials - Property of IBM                                             */
/*   US Government Users Restricted Rights - Use, duplication or                      */
/*   disclosure restricted by GSA ADP Schedule Contract with IBM Corp.                */
/*                                                                                    */
/*====================================================================================*/

/* eci.h  */

#ifndef __ECI_H
#define __ECI_H

typedef int ECIBoolean;
#ifndef __cplusplus
#define true  1
#define false  0
#endif

/***************************************************************************
        macros, constants, and enums
***************************************************************************/

#ifndef ECIFNDECLARE
        typedef signed long ECIint32;
#ifdef _MSC_VER
        /*      Microsoft Compiler */
        #ifdef _WIN32_WCE
                /*      Microsoft Windows CE */
                //haric ce port
                typedef char ECIsystemChar;     /*      Microsoft Windows CE requires 16-bit characters */
                #define ECIFNDECLARE __stdcall
        #elif defined _WIN32
                #include <tchar.h>
                /*      Microsoft 32-bit Windows (not CE) */
                typedef _TCHAR ECIsystemChar;
                #define ECIFNDECLARE __stdcall
        #endif  /* Microsoft Windows*/

#elif defined __TURBOC__
        /*      Borland Compiler */
        #ifdef __WIN32__
                #include <tchar.h>
                /*      Microsoft Windows */
                #define ECIFNDECLARE __stdcall
                typedef _TCHAR ECIsystemChar;
        #endif  /*      Microsoft Windows */
#else   /*      Add your compiler and platform here. */
        /*      Default options */
        #define ECIFNDECLARE
        typedef char ECIsystemChar;
#endif
#endif

#ifndef NULL_ECI_HAND
 #define NULL_ECI_HAND  0
#endif

#define ECI_PRESET_VOICES  8
#define ECI_USER_DEFINED_VOICES  8

#define ECI_VOICE_NAME_LENGTH  30

#define ECI_SYSTEMERROR  0x01
#define ECI_MEMORYERROR  0x02
#define ECI_MODULELOADERROR  0x04
#define ECI_DELTAERROR  0x08
#define ECI_SYNTHERROR  0x10
#define ECI_DEVICEERROR  0x20
#define ECI_DICTERROR	0x40
#define ECI_PARAMETERERROR 0x80
#define ECI_SYNTHESIZINGERROR 0x0100
#define ECI_DEVICEBUSY 0x0200
#define ECI_SYNTHESISPAUSED 0x0400

//Largest number of characters in a single SPR phoneme
#define eciPhonemeLength (4)

/***************************************************************************
	typedefs, structs, classes
***************************************************************************/

#ifdef __cplusplus
extern "C" {
#endif

typedef void* ECIHand;

typedef const char* ECIInputText;

typedef enum {
	eciSynthMode,
	eciInputType,
	eciTextMode,
	eciDictionary,
	eciSampleRate = 5,
    eciWantPhonemeIndices = 7,
	eciRealWorldUnits,
	eciLanguageDialect,
    eciNumberMode,
	eciPhrasePrediction,
	eciNumParams
} ECIParam;

typedef enum {
	eciGender,
	eciHeadSize,
	eciPitchBaseline,
	eciPitchFluctuation,
	eciRoughness,
	eciBreathiness,
	eciSpeed,
	eciVolume,
	eciNumVoiceParams
} ECIVoiceParam;

//  Enumerate the possible dictionary errors that can occur.
typedef enum
{
  DictNoError,					//  Everything is OK.
  DictFileNotFound,        		//  Had trouble finding or opening the dictionary file.
  DictOutOfMemory,              //  No memory left when building hash table or
  								//  allocating space for keys and translations.
  DictInternalError,			//  Error occured when calling into Delta.
  DictNoEntry, 					//  No more entries in the dictionary.
  DictErrLookUpKey,				//  Error looking up the key in the hash table.
  DictAccessError				//  Error acessing the dictionary.
} ECIDictError;

typedef void* ECIDictHand;
#define NULL_DICT_HAND 0
typedef enum {
	eciMainDict = 0,
	eciRootDict = 1,
    eciAbbvDict = 2
} ECIDictVolume;

typedef enum
{
	eciGeneralAmericanEnglish = 0x00010000,
   eciBritishEnglish         = 0x00010001,
   eciCastilianSpanish      = 0x00020000,
   eciMexicanSpanish         = 0x00020001,
   eciStandardFrench         = 0x00030000,
   eciCanadianFrench         = 0x00030001,
   eciStandardGerman         = 0x00040000,
   eciStandardItalian        = 0x00050000,
   eciSimplifiedChinese      = 0x00060000,
   eciBrazilianPortuguese    = 0x00070000
}  ECILanguageDialect;

#if defined(WIN32)
#pragma pack(push, 1)
#elif defined(UNDER_CE) && (defined(MIPS) || defined(SH3))
#pragma pack(push, 4)
#endif
typedef struct {
	char szPhoneme[eciPhonemeLength+1];  // Null terminated string containing SPR phoneme
   ECILanguageDialect eciLanguageDialect; //Language/Dialect associated with phoneme
	unsigned char mouthHeight;  // 0-255
	unsigned char mouthWidth;  // 0-255
	unsigned char mouthUpturn;  // 0-128 (neutral)-255
	unsigned char jawOpen;  // 0-255
	unsigned char teethUpperVisible;  // 0 (hidden)-128 (teeth visible)-255 (teeth & gums)
	unsigned char teethLowerVisible;  // ditto
	unsigned char tonguePosn;  // 0 (relaxed)-128 (visible)-255 (against upper teeth)
	unsigned char lipTension;  // 0-255
} ECIMouthData;
#if defined(WIN32) || defined(UNDER_CE)
#pragma pack(pop)
#endif

typedef enum {
	eciWaveformBuffer, eciPhonemeBuffer, eciIndexReply, eciPhonemeIndexReply
} ECIMessage;

typedef enum {
	eciDataNotProcessed, eciDataProcessed
} ECICallbackReturn;

typedef ECICallbackReturn (* ECICallback)(ECIHand eciInstance, ECIMessage msg, long param, void* data);

#if defined(_WIN32) || defined(_Windows)
typedef enum {
	eciGeneralDB,
	eciAboutDB,
	eciVoicesDB,
	eciReadingDB,
	eciMainDictionaryDB,
	eciRootDictionaryDB,
	eciNumDialogBoxes
} ECIDialogBox;
#endif


#ifdef __cplusplus
}
#endif

/***************************************************************************
	public variables
***************************************************************************/

/***************************************************************************
	function prototypes
***************************************************************************/

#ifdef __cplusplus
extern "C" {
#endif

ECIHand ECIFNDECLARE eciNew(void);
ECIHand ECIFNDECLARE eciDelete(ECIHand eciHandle);
ECIBoolean ECIFNDECLARE eciReset(ECIHand eciHandle);
void ECIFNDECLARE eciVersion(char* buffer);
int ECIFNDECLARE eciProgStatus(ECIHand eciHandle);
void ECIFNDECLARE eciErrorMessage(ECIHand eciHandle, char* buffer);
void ECIFNDECLARE eciClearErrors(ECIHand eciInstance);
ECIBoolean ECIFNDECLARE eciTestPhrase(ECIHand eciHandle);
ECIBoolean ECIFNDECLARE eciSpeakText(ECIInputText text, ECIBoolean bAnnotationsInTextPhrase);/*59217*/
int ECIFNDECLARE eciGetParam(ECIHand eciHandle, ECIParam parameter);
int ECIFNDECLARE eciSetParam(ECIHand eciHandle, ECIParam parameter, int value);
ECIBoolean ECIFNDECLARE eciCopyVoice(ECIHand eciHandle, int voiceFrom, int voiceTo);
ECIBoolean ECIFNDECLARE eciGetVoiceName(ECIHand eciInstance, int voice, char* nameBuffer);
ECIBoolean ECIFNDECLARE eciSetVoiceName(ECIHand eciInstance, int voice, const char* name);
int ECIFNDECLARE eciGetVoiceParam(ECIHand eciHandle, int voice, ECIVoiceParam parameter);
int ECIFNDECLARE eciSetVoiceParam(ECIHand eciHandle, int voice,
	ECIVoiceParam parameter, int value);
ECIBoolean ECIFNDECLARE eciAddText(ECIHand eciHandle, ECIInputText text);
ECIBoolean ECIFNDECLARE eciInsertIndex(ECIHand eciHandle, int index);
ECIBoolean ECIFNDECLARE eciSynthesize(ECIHand eciHandle);
ECIBoolean ECIFNDECLARE eciSynthesizeFile(ECIHand eciHandle, const char* filename);
ECIBoolean ECIFNDECLARE eciClearInput(ECIHand eciHandle);
ECIBoolean ECIFNDECLARE eciGeneratePhonemes(ECIHand eciHandle, int size, char* buffer);
int ECIFNDECLARE eciGetIndex(ECIHand eciInstance);
ECIBoolean ECIFNDECLARE eciStop(ECIHand eciHandle);
ECIBoolean ECIFNDECLARE eciSpeaking(ECIHand eciInstance);
ECIBoolean ECIFNDECLARE eciSynchronize(ECIHand eciHandle);
void ECIFNDECLARE eciSynchronizeSynth(ECIHand eciHandle);
ECIBoolean ECIFNDECLARE eciSetOutputBuffer(ECIHand eciInstance, int size, short* buffer);
ECIBoolean ECIFNDECLARE eciSetOutputFilename(ECIHand eciInstance, const char* filename);
ECIBoolean ECIFNDECLARE eciSetOutputDevice(ECIHand eciInstance, int deviceNum);
ECIBoolean ECIFNDECLARE eciPause(ECIHand eciInstance, ECIBoolean on);
void ECIFNDECLARE eciRegisterCallback(ECIHand eciHandle, ECICallback callback, void* data);

ECIDictHand ECIFNDECLARE eciNewDict(ECIHand eciHandle);
ECIDictHand ECIFNDECLARE eciGetDict(ECIHand whichECI);
ECIDictError ECIFNDECLARE eciSetDict(ECIHand whichECI, ECIDictHand whichDictHand);
ECIDictHand ECIFNDECLARE eciDeleteDict(ECIHand whichECI, ECIDictHand whichDictHand);
ECIDictError ECIFNDECLARE eciLoadDict(ECIHand whichECI, ECIDictHand whichDictHand, ECIDictVolume whichDictionary, const char* filename);
ECIDictError ECIFNDECLARE eciSaveDict(ECIHand whichECI, ECIDictHand whichDictHand, ECIDictVolume whichDictionary, const char* filename);
ECIDictError ECIFNDECLARE eciUpdateDict(ECIHand whichECI, ECIDictHand whichDictHand,
	ECIDictVolume whichDictionary, const char* key, const char* translationValue);

ECIDictError ECIFNDECLARE eciDictFindFirst(ECIHand  whichECI,
						ECIDictHand  whichDictHand, ECIDictVolume whichDictionary,
							const char * *key, const char * *translationValue);
ECIDictError ECIFNDECLARE eciDictFindNext(ECIHand  whichECI,
						ECIDictHand  whichDictHand, ECIDictVolume whichDictionary,
							const char * *key, const char * *translationValue);
const char * ECIFNDECLARE eciDictLookup(ECIHand  whichECI,
						ECIDictHand  whichDictHand, ECIDictVolume whichDictionary,
							const char *key);

#if defined(_WIN32) || defined(_Windows)
void ECIFNDECLARE eciStartLogging(ECIHand  whichECI);
void ECIFNDECLARE eciStopLogging(ECIHand  whichECI);
char *ECIFNDECLARE eciGetLog(ECIHand  whichECI);
int *ECIFNDECLARE eciGetIntLog(ECIHand  whichECI, int *pLength);
ECIBoolean ECIFNDECLARE eciDialogBox(ECIHand eciHandle,
			void * parentWindow, ECIDialogBox dialogBox, const char * title,
			unsigned long int controlSuppressionFlags);
#define  ECI_SUPPRESS_GENERAL_READING 	0x0001
#define  ECI_SUPPRESS_GENERAL_VOICES    0x0002
#define  ECI_SUPPRESS_GENERAL_MAIN_DICT 0x0004
#define  ECI_SUPPRESS_GENERAL_ROOT_DICT 0x0008
#define  ECI_SUPPRESS_GENERAL_ABBR_DICT 0x0010
#define  ECI_SUPPRESS_VOICES_SET_DEFAULTS  0x0080
#define  ECI_SUPPRESS_DICT_LOAD_SAVE    0x0100
#endif

void ECIFNDECLARE eciRequestLicense(int licenseCode);

#ifdef __cplusplus
}
#endif

#endif  // __ECI_H
