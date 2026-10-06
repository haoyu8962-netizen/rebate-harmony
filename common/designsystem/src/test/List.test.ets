import designTokensMappingTest from './DesignTokensMapping.test';
import formatVectorTest from './FormatVector.test';
import priceModelEdgeTest from './PriceModelEdge.test';
import round3Test from './Round3.test';

export default function testsuite() {
  designTokensMappingTest();
  formatVectorTest();
  priceModelEdgeTest();
  round3Test();
}
