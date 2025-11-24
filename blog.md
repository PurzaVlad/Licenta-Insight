# **Build a React Native App to Chat locally with an LLM: A Step-by-Step Guide**

Did you ever wonder how you can create a mobile app to chat with LLMs locally? Have you tried to understand the code in some open source projects but found it too complex? Well, this blog is for you! We will help you build a simple React Native app to chat with LLMs downloaded from the **Hugging Face** hub. React Native makes it easy to create cross-platform mobile apps, and Large Language Models (LLMs) have brought conversational AI into the spotlight. In this guide, we'll walk through building a simple React Native app that lets users chat with an LLM locally, without the need of an API - everything is private and runs on device.

---

## **Why This Tutorial?**
This blog is for anyone who:
- Is curious about integrating AI into mobile apps
- Wants to build a conversational app that works on both Android and iOS
- Is interested in privacy-focused AI applications that run completely offline

By the end of this guide, you'll have a working app to chat with your favorite smol hub models.

---

## **1. Setting Up Your Environment**
React Native requires some setup before you can start coding.

### **Tools You Need**
1. **Node.js:** Install from [Node.js downloads](https://nodejs.org/en/download)
2. **react-native-community/cli:** Run the following to install:
```bash
npm i @react-native-community/cli
```

### **Emulator Setup**
To run your app during development you will need an emulator:

- **For Mac Users:**
  - Can run both Android and iOS emulators
  - For iOS: Install Xcode -> Open Developer Tools -> Simulator
  - For Android: Install Java Runtime and Android Studio -> Go to Device Manager and Create an emulator

- **For PC Users:**
  - Install Java Runtime and Android Studio for Android development
  - For iOS testing options:
    - Cloud-based simulators like [LambdaTest](https://www.lambdatest.com/test-on-iphone-simulator) and [BrowserStack](https://www.browserstack.com/test-on-ios-simulator)
    - Third party emulators that try to mimic iOS behavior but we didn't test them.

Follow the excellent tutorial by Expo for Android Studio setup: [Android Studio Emulator Guide](https://docs.expo.dev/workflow/android-studio-emulator/)

## **2. Create the App**

Let's start this project! First, we need to initiate the app using @react-native-community/cli:
```bash
npx @react-native-community/cli@latest init <ProjectName>
```

### **Project Structure**
The app folder architecture for a new project includes:

#### **Default Files/Folders**

1. `android/`
   - Contains native Android project files 
   - **Purpose**: To build and run the app on Android devices

2. `ios/`
   - Contains native iOS project files
   - **Purpose**: To build and run the app on iOS devices

3. `node_modules/`
   - **Purpose**: Holds all npm dependencies used in the project

4. `App.js`
   - The main root component of your app
   - **Purpose**: Entry point to the app's UI and logic

5. `index.js`
   - Registers the root component (`App`)
   - **Purpose**: Entry point for React Native runtime


#### **Additional Configuration Files**

- `tsconfig.json`: Configures TypeScript settings
```json
{
  "compilerOptions": {
    "target": "es5",
    "module": "commonjs",
    "jsx": "react",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*"]
}
```


- `babel.config.js`: Configures Babel for transpiling modern JavaScript/TypeScript.
- `jest.config.js`: Configures Jest for testing React Native components and logic.
- `metro.config.js`: Customizes the Metro bundler for the project. The Metro bundler is a JavaScript bundler specifically designed for React Native. It takes your project’s JavaScript and assets, bundles them into a single file (or multiple files for efficient loading), and serves them to the app during development. Metro is optimized for fast incremental builds, supports hot reloading, and handles React Native’s platform-specific files (.ios.js or .android.js). It ensures your app gets the right code and assets.
- `.watchmanconfig`: Configures Watchman, a file-watching service used by React Native for hot reloading.

## **3. How to Debug**

### **Running the App**

Debugging a React Native application requires either an emulator or a physical device. We'll focus on using an emulator since it provides a more streamlined development experience with your code editor and debugging tools side by side.

Start by ensuring your development environment is ready:
```bash
# Install dependencies
npm install

# Start the Metro bundler
npm start
```

In a new terminal, launch the app on your chosen platform:
```bash
# For iOS
npm run ios

# For Android
npm run android
```
This should launch the app on your emulator. 


### **Chrome DevTools Debugging**

For debugging you will use Chrome DevTools as in web development : 


1. Press `j` in the Metro bundler terminal to launch Chrome DevTools

![alt text](assets/blog_images/dev_tools.png)

2. Navigate to the "Sources" tab
3. Find your source files
4. Set breakpoints by clicking on line numbers
5. Use debugging controls:
   - Step Over - Execute current line
   - Step Into - Enter function call
   - Step Out - Exit current function
   - Continue - Run until next breakpoint

### **Common Debugging Tips**

1. **Console Logging**
```javascript
console.log('Debug value:', someValue);
console.warn('Warning message');
console.error('Error details');
```
2. **Metro Bundler Issues**
```bash
# Clear Metro bundler cache
npm start -- --reset-cache
```
3. **Build Errors**
```bash
# Clean and rebuild
cd android && ./gradlew clean
cd ios && pod install
```

## **4. App Implementation**

### **Installing Dependencies**
First, let's install the required packages. We aim to load models from the Hugging Face Hub and run them locally. To achieve this, we need to install : 

- `llama.rn`: a binding for `llama.cpp` tailored for React Native apps.  
- `react-native-fs`: allows us to manage the device's file system in a React Native environment.  
- `axios`: a library for sending requests to the Hugging Face Hub API.

```bash
npm install axios react-native-fs llama.rn
```
Let's run the app on our simulator so we can start the development 

### **State Management**
We will start by deleting everyting from the App.tsx file, and creating an empty code structure like the following : 
```typescript
import React from 'react';
import {
  StyleSheet,
  View,
} from 'react-native';

function App(): React.JSX.Element {

  return (
    <View> </View>
  );
}
const styles = StyleSheet.create({});

export default App;
```
Next, let's start by thinking about the state management, what kind of variables would we need to keep track off in our application ? Of course, we need to keep track of the list of available models, the conversation, the selected model, the user input  
```typescript
type Message = {
  role: 'User' | 'Assistant';
  content: string;
};

const [context, setContext] = useState<any>(null);
const [conversation, setConversation] = useState<Message[]>([
  {role: 'Assistant', content: 'Hi there! How can I help you today?'}
]);
const [selectedModelFormat, setSelectedModelFormat] = useState<string>('');
const [selectedGGUF, setSelectedGGUF] = useState<string | null>(null);
const [availableGGUFs, setAvailableGGUFs] = useState<string[]>([]);
```
The Message type defines the structure of chat messages, specifying that each message must have a role (either 'User' or 'Assistant') and content (the actual message text). We then create several state variables: context to store the initialized LLM model, conversation to keep track of the chat history (initialized with a welcome message), selectedModelFormat to store which model the user selects (like Llama or Qwen), selectedGGUF to store the specific model file chosen, and availableGGUFs to store the list of model files that can be downloaded. 

### **Model Configuration**
We then define the available models and their repositories:

```typescript
const HF_TO_GGUF = {
  'Llama-3.2-1B-Instruct': 'bartowski/Llama-3.2-1B-Instruct-GGUF',
  'DeepSeek-R1-Distill-Qwen-1.5B': 'bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF',
  'Qwen2-1.5B-Instruct': 'Qwen/Qwen2-0.5B-Instruct-GGUF'
};

const modelFormats = [
  {label: 'Llama-3.2-1B-Instruct'},
  {label: 'Qwen2-1.5B-Instruct'},
  {label: 'DeepSeek-R1-Distill-Qwen-1.5B'}
];
```
 Our HF_TO_GGUF object creates a mapping between user-friendly model names and their corresponding Hugging Face repository paths - for example, when a user selects 'Llama-3.2-1B-Instruct', we'll know to fetch it from 'bartowski/Llama-3.2-1B-Instruct-GGUF' repository. Our modelFormats array defines the list of models that we'll display to users in the selection screen.

### **Fetching Available Models**

we create a way to fetch and display available GGUF model files from Hugging Face for our selected model format. When a user selects a model format, we make an API call to Hugging Face using the repository path we mapped in our HF_TO_GGUF object. We're specifically looking for files that end with '.gguf' extension, which are our quantized model files. Once we receive the response, we extract just the filenames of these GGUF files and store them in our availableGGUFs state using setAvailableGGUFs. This allows us to show users a list of available model variants they can download.

```typescript
const fetchAvailableGGUFs = async (modelFormat: string) => {
  try {
    const response = await axios.get(
      `https://huggingface.co/api/models/${
        HF_TO_GGUF[modelFormat as keyof typeof HF_TO_GGUF]
      }`
    );
    const files = response.data.siblings.filter((file: any) =>
      file.rfilename.endsWith('.gguf')
    );
    setAvailableGGUFs(files.map((file: any) => file.rfilename));
  } catch (error) {
    Alert.alert('Error', 'Failed to fetch .gguf files from Hugging Face API.');
  }
};
```

### **Model Download Implementation**
We then Implement the download functionality and store the downloaded file in the Documents folder of the application :

```typescript
const handleDownloadModel = async () => {
  if (!selectedGGUF) {
    Alert.alert('Error', 'Please select a model file to download.');
    return;
  }

  const downloadUrl = `https://huggingface.co/${
    HF_TO_GGUF[selectedModelFormat as keyof typeof HF_TO_GGUF]
  }/resolve/main/${selectedGGUF}`;
  
  setIsDownloading(true);
  setProgress(0);

  try {
    const destPath = await downloadModel(
      selectedGGUF,
      downloadUrl,
      progress => setProgress(progress)
    );
    await loadModel(selectedGGUF);
  } catch (error) {
    Alert.alert('Error', `Download failed: ${error.message}`);
  } finally {
    setIsDownloading(false);
  }
};
```

The `downloadModel` function, located in `src/api`, accepts three parameters: `modelName`, `downloadUrl`, and a `progress` callback function. This callback is triggered during the download process to update the progress. Using the `RNFS` module from `react-native-fs`, the model is stored in the app's Documents folder, and the progress bar is updated accordingly.

Additionally, we have a progress bar component defined in the `components` folder, which reflects the current download progress whenever it's updated.

### **Model Loading and Initialization**
Next, we create a function to load the downloaded model into a Llama context, following the documentation of `llama.rn` available [here](https://github.com/mybigday/llama.rn). If a context is already loaded, we release it, set it to `null`, and reset the conversation to its initial state. After that, we use the `initLlama` function to load the model into a new context and update the context with the newly initialized one.
```typescript
const loadModel = async (modelName: string) => {
  try {
    const destPath = `${RNFS.DocumentDirectoryPath}/${modelName}`;
    
    if (context) {
      await releaseAllLlama();
      setContext(null);
      setConversation(INITIAL_CONVERSATION);
    }
    
    const llamaContext = await initLlama({
      model: destPath,
      use_mlock: true,
      n_ctx: 2048,
      n_gpu_layers: 1
    });
    
    setContext(llamaContext);
    return true;
  } catch (error) {
    Alert.alert('Error Loading Model', error.message);
    return false;
  }
};
```

### **Chat Implementation**
Following that, we build the chat interface to display the conversation history alongside the user input field. The user's input is sent to the model, and the model's response is rendered within the chat interface. 

```typescript
const handleSendMessage = async () => {
  if (!context || !userInput.trim()) {
    return;
  }

  const newConversation = [
    ...conversation,
    {role: 'User', content: userInput}
  ];
  setConversation(newConversation);
  setUserInput('');
  
  try {
    const stopWords = ['</s>', '<|end|>', 'User:', 'Assistant:', '<|im_end|>'];
    const result = await context.completion({
      messages: newConversation,
      n_predict: 100,
      stop: stopWords
    });

    setConversation([
      ...newConversation,
      {role: 'Assistant', content: result.text.trim()}
    ]);
    
    setTokensPerSecond([
      ...tokensPerSecond,
      parseFloat(result.timings.predicted_per_second.toFixed(2))
    ]);
  } catch (error) {
    Alert.alert('Error During Inference', error.message);
  }
};
```
Whenever the user submits an input, we update the conversation state and pass it to the model using `context.completion`. The model's response is retrieved and used to update the conversation again. Additionally, we access the timings included in the model's results to display the inference speed.  

### **The UI**
The UI is straightforward, consisting of a model selection screen with a list of models and a chat interface that includes a conversation history and a user input field. During the model download phase, a progress bar is displayed. We intentionally avoid adding many screens to keep the app simple and focused on its core functionality.  
## **4. Testing the App**

To run and test your app:

1. Start the Metro bundler:
```bash
npm start
```

2. In a new terminal, run the app:
```bash
npm run android  # For Android
# or
npm run ios     # For iOS
```
![alt text](assets/blog_images/app_screenshot.png)
## **5. Key Features**

Our implemented app includes:
- Model selection and download from Hugging Face
- Local model initialization and inference
- Real-time chat interface
- Inference speed tracking
- Progress tracking for downloads
- Clean, intuitive UI

## **6. Performance Tips**

1. **Model Selection:**
   - Choose smaller quantized models (4-bit or 8-bit)
   - Consider model size vs. performance tradeoffs

2. **Memory Management:**
   - Properly release model context when switching models
   - Monitor device memory usage

3. **UI Responsiveness:**
   - Use proper state management
   - Implement loading states
   - Handle errors gracefully

## **7. Conclusion**

You now have a working React Native app that can:
- Download models from Hugging Face
- Run inference locally
- Provide a smooth chat experience
- Track model performance

This implementation serves as a foundation for building more sophisticated AI-powered mobile applications. Remember to consider device capabilities when selecting models and tuning parameters.

Happy coding! 🚀
