import React from 'react';
import {requireNativeComponent, ViewStyle} from 'react-native';

type Props = {
  style?: ViewStyle;
};

const RNNativeChatView = requireNativeComponent<Props>('NativeChatView');

export default function NativeChatView(props: Props) {
  return <RNNativeChatView {...props} />;
}
