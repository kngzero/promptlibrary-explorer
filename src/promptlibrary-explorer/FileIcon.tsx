import React from 'react';
import plibIcon from './assets/plib-icon.svg';

interface FileIconProps {
  className?: string;
}

const PlibIcon: React.FC<FileIconProps> = ({ className }) => {
  return <img src={plibIcon} alt="PLIB file icon" className={className} />;
};

export default PlibIcon;
