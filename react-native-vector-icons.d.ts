declare module 'react-native-vector-icons/MaterialCommunityIcons' {
  import * as React from 'react';
  import {TextStyle, ViewStyle} from 'react-native';

  type IconStyle = TextStyle | ViewStyle;

  export interface IconProps {
    name: string;
    size?: number;
    color?: string;
    style?: IconStyle;
  }

  export default class Icon extends React.Component<IconProps> {}
}
