import designTokensMappingTest from './DesignTokensMapping.test';
import formatVectorTest from './FormatVector.test';
import priceModelEdgeTest from './PriceModelEdge.test';
import round3Test from './Round3.test';
import loginLayoutTest from './LoginLayout.test';
import productCardMapperR1Test from './ProductCardMapperR1.test';
import followupHM1112Test from './FollowupHM1112.test';
import app06bProvisionalTest from './App06bProvisional.test';
import app06bReviewR1Test from './App06bReviewR1.test';
import app06bReviewR2Test from './App06bReviewR2.test';

export default function testsuite() {
  designTokensMappingTest();
  formatVectorTest();
  priceModelEdgeTest();
  round3Test();
  loginLayoutTest();
  productCardMapperR1Test();
  followupHM1112Test();
  app06bProvisionalTest();
  app06bReviewR1Test();
  app06bReviewR2Test();
}
