import contractConformanceTest from './ContractConformance.test';
import tokensPipeTest from './TokensPipe.test';

export default function testsuite() {
  contractConformanceTest();
  tokensPipeTest();
}
